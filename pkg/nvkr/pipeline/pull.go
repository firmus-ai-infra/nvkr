// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package pipeline

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dsx-ai-factory/nvkr/internal/releaseasset"
	"github.com/dsx-ai-factory/nvkr/internal/securepath"
	e "github.com/dsx-ai-factory/nvkr/pkg/nvkr/errors"
	"github.com/dsx-ai-factory/nvkr/pkg/nvkr/internal/heldfile"
	"github.com/dsx-ai-factory/nvkr/pkg/nvkr/ir"
	"github.com/google/go-containerregistry/pkg/name"
	"golang.org/x/sys/unix"
)

// The no-compile (prebuilt) lane. A pull node acquires a pinned, content-addressed
// artifact instead of building it from source (NVKR-FR-BLD-050). It is fail-closed: the
// acquired bytes MUST hash to the node's pinned Digest or the whole run stops
// (CodeVerifyFailed). This lane trades the from-source guarantee — "the same inputs
// rebuild the same bytes" — for a content-addressed one — "exactly these pinned bytes";
// it is deliberately NOT a byte reproduction of a build, and claims none.

// pull acquires one prebuilt artifact: an OCI image (pulled by digest) or an https
// binary (downloaded and hash-verified).
func (l Local) pull(n ir.Node, opts RunOptions) (*ArtifactResult, error) {
	if err := n.Validate(); err != nil {
		return nil, err
	}
	if n.OutputType == "oci-image" {
		return l.pullImage(n, opts)
	}
	return l.pullBinary(n, opts)
}

// pullImage acquires a complete OCI image/layout by its pinned manifest digest without
// a daemon or mounted runtime socket. The registry adapter writes into a private
// temporary layout, verifies the complete descriptor/blob closure, and publishes the
// directory atomically. Terminal verification walks the layout again with no network.
func (l Local) pullImage(n ir.Node, opts RunOptions) (*ArtifactResult, error) {
	parsed, err := name.ParseReference(n.Artifact)
	if err != nil {
		return nil, e.Wrap(e.CodeUnverifiedRef, err, "parse acquired OCI image")
	}
	ref, err := ir.NativeImageReference(n)
	if err != nil {
		return nil, err
	}
	parent := n.ImageParentDigest
	if authored, ok := parsed.(name.Digest); ok && parent == "" {
		parent = authored.DigestStr()
	}
	var native registryOCITransport
	if parent != "" {
		var supported bool
		native, supported = opts.OCI.(registryOCITransport)
		if !supported {
			return nil, e.New(e.CodeEngineCapability, "selected OCI transport cannot authenticate parent/native membership")
		}
	}
	dir := prebuiltDir(opts, n)
	layoutPath := filepath.Join(dir, sanitizeName(n.Component)+".oci")
	if opts.DryRun {
		fmt.Fprintf(opts.Stdout, "[pull:%s] acquire complete OCI closure %s -> %s (verify %s)\n", n.Component, ref, layoutPath, n.Digest)
		return nil, nil
	}
	// The bound owner authenticates parent/child before creating any output.
	if parent == "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, e.Wrap(e.CodeFetchFailed, err, "creating OCI transport dir for %s", n.Component)
		}
	}
	fmt.Fprintf(opts.Stdout, "\n=== pull %s (image %s) ===\n", n.Component, ref)
	var got string
	var size int64
	if parent != "" {
		got, size, err = native.acquireNative(opts.ctx(), parsed.Context().Digest(parent).Name(), ref, n.Platform, layoutPath)
	} else {
		got, size, err = opts.OCI.Acquire(opts.ctx(), ref, layoutPath)
	}
	if err != nil {
		return nil, err
	}
	if got != n.Digest {
		return nil, e.New(e.CodeVerifyFailed, "OCI adapter returned digest %s for %s, want %s", got, ref, n.Digest)
	}
	return &ArtifactResult{
		Component:     n.Component,
		OutputType:    n.OutputType,
		Qualification: ArtifactProfileFreeAcquisition,
		EngineClass:   ir.EnginePrebuiltAcquire,
		Path:          ref,
		Ref:           ref,
		TransportPath: layoutPath,
		SHA256:        n.Digest,
		Size:          size,
		Packaged:      true,
	}, nil
}

// pullBinary downloads an https binary artifact, verifies its sha256 against the pin
// (fail closed), and — for a host-package delivery — assembles it into a reproducible
// .deb exactly as the from-source lane does. A raw delivery keeps the binary digest
// (which equals the pin).
func (l Local) pullBinary(n ir.Node, opts RunOptions) (*ArtifactResult, error) {
	dir := prebuiltDir(opts, n)
	name := n.ArtifactPath
	if name == "" {
		name = n.Component
	}
	dest, err := pathWithin(dir, name)
	if err != nil {
		return nil, e.Wrap(e.CodeFetchFailed, err, "resolving prebuilt artifact path for %s", n.Component)
	}

	if opts.DryRun {
		fmt.Fprintf(opts.Stdout, "[pull:%s] GET %s -> %s (verify sha256 %s)\n",
			n.Component, n.Artifact, dest, abbrev(strings.TrimPrefix(n.Digest, "sha256:")))
		return nil, nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, e.Wrap(e.CodeFetchFailed, err, "creating fetch dir for %s", n.Component)
	}
	fmt.Fprintf(opts.Stdout, "\n=== pull %s (%s) ===\n", n.Component, n.Artifact)
	var sum string
	var size int64
	if n.ExecutableArchive != nil {
		sum, size, err = downloadReleaseExecutableWithTransport(opts.ctx(), n, dir, name, opts.releaseExecutableTransport)
	} else if strings.HasPrefix(n.Artifact, ir.OCIBlobScheme) {
		sum, size, err = downloadOCIBlobVerify(opts.ctx(), n.Artifact, dir, name, n.Digest)
	} else {
		sum, size, err = downloadVerify(opts.ctx(), n.Artifact, dir, name, n.Digest)
	}
	if err != nil {
		return nil, err
	}
	res := &ArtifactResult{
		Component:     n.Component,
		OutputType:    n.OutputType,
		Qualification: ArtifactProfileFreeAcquisition,
		EngineClass:   ir.EnginePrebuiltAcquire,
		Path:          dest,
		SHA256:        sum,
		Size:          size,
		AbsPath:       dest,
	}
	if opts.Package && n.OutputType == "host-package" {
		if err := packageArtifact(n, dest, opts, res); err != nil {
			return nil, err
		}
	}
	return res, nil
}

// downloadReleaseExecutableWithTransport verifies the archive before selecting
// a member, then verifies the executable before atomic output publication. The
// carrier remains private and is never passed to a shell or extracted to disk.
func downloadReleaseExecutableWithTransport(ctx context.Context, node ir.Node, root, relative string, transport http.RoundTripper) (string, int64, error) {
	client := &http.Client{Transport: transport, Timeout: 10 * time.Minute, CheckRedirect: func(request *http.Request, via []*http.Request) error {
		if request.URL.Scheme != "https" || request.URL.User != nil || len(via) >= 10 {
			return e.New(e.CodeFetchFailed, "unsafe release executable redirect")
		}
		return nil
	}}
	if ctx != nil {
		if _, bounded := ctx.Deadline(); bounded {
			client.Timeout = 0 // The request carries the selected work deadline.
		}
	}
	return downloadReleaseExecutableWithClient(ctx, node, root, relative, client)
}

func downloadReleaseExecutableWithClient(ctx context.Context, node ir.Node, root, relative string, client *http.Client) (string, int64, error) {
	if ctx == nil || client == nil || node.ExecutableArchive == nil {
		return "", 0, e.New(e.CodeUsage, "release acquisition requires a context, client and archive pin")
	}
	if err := ctx.Err(); err != nil {
		return "", 0, e.Wrap(e.CodeTimeout, err, "release acquisition canceled")
	}
	if err := node.Validate(); err != nil {
		return "", 0, err
	}
	const maxReleaseBytes = releaseasset.MaxToolTransportBytes
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, node.Artifact, nil)
	if err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "creating release request")
	}
	response, err := client.Do(request)
	if err != nil {
		return "", 0, mapCancellation(ctx, e.Wrap(e.CodeFetchFailed, err, "fetching release archive"), "acquiring release executable")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", 0, e.New(e.CodeFetchFailed, "release archive returned HTTP %d", response.StatusCode)
	}
	// The existing owner authenticates and freezes the already-open stream. No
	// archive pathname is published or reopened, including in the output root.
	held, err := heldfile.FromReaderContext(ctx, response.Body, heldfile.Options{
		Label: "release-archive", MaxBytes: maxReleaseBytes,
	})
	if err != nil {
		return "", 0, mapCancellation(ctx, e.Wrap(e.CodeFetchFailed, err, "snapshotting release carrier"), "acquiring release executable")
	}
	defer func() { _ = held.Close() }()
	if held.Digest() != node.ExecutableArchive.Digest {
		return "", 0, e.New(e.CodeVerifyFailed, "release carrier digest %s does not match pinned %s", held.Digest(), node.ExecutableArchive.Digest)
	}
	member, err := releaseasset.Select(ctx, held, held.Size(), node.ExecutableArchive.Format, node.ExecutableArchive.Member, releaseasset.ToolLimits())
	if err != nil {
		return "", 0, err
	}
	if err := held.Close(); err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "closing authenticated release carrier")
	}
	return writeVerifiedDownload(ctx, bytes.NewReader(member), node.Artifact, root, relative, node.Digest, maxReleaseBytes)
}

const (
	downloadAttempts     = 3
	downloadStallTimeout = 2 * time.Minute
	downloadRetryBackoff = 15 * time.Second
)

type downloadVerifyOptions struct {
	attempts     int
	stallTimeout time.Duration
	retryBackoff time.Duration
}

var defaultDownloadVerifyOptions = downloadVerifyOptions{
	attempts:     downloadAttempts,
	stallTimeout: downloadStallTimeout,
	retryBackoff: downloadRetryBackoff,
}

// downloadVerify streams url into a private sibling while hashing, and publishes it
// only after the bytes match want (sha256:<hex>) and the file is durable. The parent
// path is held descriptor-relative with O_NOFOLLOW; renameat replaces a pre-existing
// destination symlink itself instead of following it to a host target. Every error
// unlinks only the private temporary file and leaves any prior destination untouched.
//
// An exact-byte download can be safely retried after a transient transport failure:
// each attempt starts with a private sibling and only publishes after digest
// verification. A slow transfer is admitted as long as it makes progress; an idle
// response is bounded and retried with backoff.
func downloadVerify(ctx context.Context, url, root, relative, want string) (string, int64, error) {
	return downloadVerifyWithOptions(ctx, url, root, relative, want, defaultDownloadVerifyOptions)
}

func downloadVerifyWithOptions(ctx context.Context, url, root, relative, want string, options downloadVerifyOptions) (string, int64, error) {
	if ctx == nil {
		return "", 0, e.New(e.CodeUsage, "downloading a pinned artifact requires a non-nil context")
	}
	if err := ctx.Err(); err != nil {
		return "", 0, e.Wrap(e.CodeTimeout, err, "downloading %s canceled", url)
	}
	if options.attempts < 1 || options.stallTimeout <= 0 || options.retryBackoff < 0 {
		return "", 0, e.New(e.CodeUsage, "download retry options must have attempts >= 1, a positive stall timeout, and a non-negative retry backoff")
	}
	var lastErr error
	for attempt := 1; attempt <= options.attempts; attempt++ {
		sum, size, err := downloadVerifyOnce(ctx, url, root, relative, want, options.stallTimeout)
		if err == nil {
			return sum, size, nil
		}
		if ctx.Err() != nil || !e.Retryable(err) || attempt == options.attempts {
			return "", 0, err
		}
		lastErr = err
		delay := time.Duration(attempt) * options.retryBackoff
		if err := waitDownloadRetry(ctx, delay); err != nil {
			return "", 0, err
		}
	}
	return "", 0, lastErr
}

func downloadVerifyOnce(ctx context.Context, url, root, relative, want string, stallTimeout time.Duration) (string, int64, error) {
	attemptCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = stallTimeout
	client := &http.Client{Transport: transport}
	req, err := http.NewRequestWithContext(attemptCtx, http.MethodGet, url, nil)
	if err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "constructing GET %s", url)
	}
	resp, err := client.Do(req)
	if err != nil {
		wrapped := e.Wrap(e.CodeFetchFailed, err, "GET %s", url)
		if isTransientDownloadError(err) {
			wrapped = e.Wrap(e.CodeUnavailable, err, "GET %s", url)
		}
		return "", 0, mapCancellation(attemptCtx, wrapped, "downloading "+url)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", 0, e.New(e.CodeFetchFailed, "GET %s: HTTP %s", url, resp.Status)
	}
	body := &downloadStallReader{source: resp.Body, cancel: cancel, timeout: stallTimeout, timer: time.AfterFunc(stallTimeout, cancel)}
	defer body.Close()
	sum, size, err := writeVerifiedDownload(attemptCtx, body, url, root, relative, want, 0)
	if err != nil && isTransientDownloadError(err) {
		return "", 0, e.Wrap(e.CodeUnavailable, err, "downloading %s", url)
	}
	return sum, size, err
}

func waitDownloadRetry(ctx context.Context, delay time.Duration) error {
	if delay == 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return e.Wrap(e.CodeTimeout, ctx.Err(), "waiting to retry download canceled")
	case <-timer.C:
		return nil
	}
}

type downloadStallReader struct {
	source  io.ReadCloser
	cancel  context.CancelFunc
	timeout time.Duration
	timer   *time.Timer
}

func (r *downloadStallReader) Read(p []byte) (int, error) {
	n, err := r.source.Read(p)
	if n > 0 {
		r.timer.Stop()
		r.timer.Reset(r.timeout)
	}
	return n, err
}

func (r *downloadStallReader) Close() error {
	r.timer.Stop()
	return r.source.Close()
}

func isTransientDownloadError(err error) bool {
	if errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
		return true
	}
	var networkErr net.Error
	return errors.As(err, &networkErr) && (networkErr.Timeout() || networkErr.Temporary())
}

// writeVerifiedDownload is shared by HTTPS files and OCI archive blobs. It never
// unpacks or transforms the stream; only the verified exact bytes are published.
// A positive limit bounds the entire stream, including a lying Content-Length.
func writeVerifiedDownload(ctx context.Context, source io.Reader, location, root, relative, want string, limit int64) (string, int64, error) {
	if err := ctx.Err(); err != nil {
		return "", 0, e.Wrap(e.CodeTimeout, err, "downloading %s canceled", location)
	}
	dest := filepath.Join(root, relative)
	parent, finalName, err := securepath.CreateParentBeneath(root, relative)
	if err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "resolving safe download destination %s", dest)
	}
	defer parent.Close()
	f, temporaryName, err := securepath.CreateTemporarySibling(parent)
	if err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "creating private download for %s", dest)
	}
	closed := false
	defer func() {
		if !closed {
			_ = f.Close()
		}
		_ = unix.Unlinkat(int(parent.Fd()), temporaryName, 0)
	}()
	h := sha256.New()
	if limit > 0 {
		source = io.LimitReader(source, limit+1)
	}
	size, copyErr := io.CopyBuffer(io.MultiWriter(f, h), pipelineContextReader{ctx: ctx, source: source}, make([]byte, 128<<10))
	if copyErr != nil {
		return "", 0, mapCancellation(ctx, e.Wrap(e.CodeFetchFailed, copyErr, "downloading %s", location), "downloading "+location)
	}
	if err := ctx.Err(); err != nil {
		return "", 0, e.Wrap(e.CodeTimeout, err, "downloading %s canceled", location)
	}
	if limit > 0 && size > limit {
		return "", 0, e.New(e.CodeFetchFailed, "download %s exceeds the %d-byte limit", location, limit)
	}
	got := "sha256:" + hex.EncodeToString(h.Sum(nil))
	if got != want {
		return "", 0, e.New(e.CodeVerifyFailed,
			"artifact digest mismatch for %s: expected %s, got %s (fail closed; the pinned artifact was not served)", location, want, got)
	}
	if err := f.Chmod(0o755); err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "setting verified download mode for %s", dest)
	}
	if err := f.Sync(); err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "syncing private download for %s", dest)
	}
	if err := ctx.Err(); err != nil {
		return "", 0, e.Wrap(e.CodeTimeout, err, "publishing downloaded artifact %s canceled", dest)
	}
	if err := f.Close(); err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "closing private download for %s", dest)
	}
	closed = true
	if err := unix.Renameat(int(parent.Fd()), temporaryName, int(parent.Fd()), finalName); err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "publishing verified download %s", dest)
	}
	if err := unix.Fsync(int(parent.Fd())); err != nil {
		return "", 0, e.Wrap(e.CodeFetchFailed, err, "syncing verified download directory for %s", dest)
	}
	return got, size, nil
}

// prebuiltDir is the per-component download directory, a sibling of the source root
// (.nvkr/work/fetch/<component>) so acquired artifacts live under the same work tree as
// from-source checkouts.
func prebuiltDir(opts RunOptions, n ir.Node) string {
	return filepath.Join(filepath.Dir(opts.SourceRoot), "fetch", sanitizeName(n.Component))
}
