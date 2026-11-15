// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package pipeline

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	nvkrerr "github.com/dsx-ai-factory/nvkr/pkg/nvkr/errors"
	"github.com/dsx-ai-factory/nvkr/pkg/nvkr/ir"
)

func TestPublicRunnerEntryPointsRejectNilContextAtAdmission(t *testing.T) {
	qualified := RunOptions{Qualification: &QualifiedExecution{}}
	if _, err := (Local{}).Run(nil, "", qualified); code(err) != nvkrerr.CodeUsage {
		t.Fatalf("Run accepted a nil context or inspected its graph first: %v", err)
	}
	if _, err := (Local{}).VerifyResults(nil, "", "missing", qualified); code(err) != nvkrerr.CodeUsage {
		t.Fatalf("VerifyResults accepted a nil context or inspected its inputs first: %v", err)
	}
	if _, err := (Local{}).ExecNode(ir.Node{}, RunOptions{}); code(err) != nvkrerr.CodeUsage {
		t.Fatalf("ExecNode accepted a nil context or inspected its node first: %v", err)
	}
}

func TestLocalRunRejectsUnsafeCallerGraphBeforeWork(t *testing.T) {
	for name, mutate := range map[string]func(*ir.Node){
		"tagged toolchain": func(node *ir.Node) { node.Toolchain = "ubuntu:latest" },
		"networked build":  func(node *ir.Node) { node.Network = ir.NetworkDefault },
	} {
		t.Run(name, func(t *testing.T) {
			graph := sampleGraph()
			mutate(&graph.Nodes[0])
			if _, err := graph.Digest(); err == nil {
				t.Fatal("unsafe graph gained a build digest")
			}
			var output bytes.Buffer
			report, err := (Local{}).Run(graph, "sha256:"+repeatHex("f"), RunOptions{Ctx: context.Background(), DryRun: true, Stdout: &output})
			if err == nil || output.Len() != 0 || report.Qualified() || len(report.Nodes) != 0 {
				t.Fatalf("unsafe graph crossed local execution seam: report=%+v output=%q err=%v", report, output.String(), err)
			}
		})
	}
}

func TestLocalRunCancellationStopsGitFetch(t *testing.T) {
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte("#!/bin/sh\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	toolchain := "registry.example/toolchain@sha256:" + repeatHex("c")
	fetch := testFetchNode("fetch-cancel", "https://example.test/source", testSourceCommit, testSourceTree,
		"source", toolchain, "sha256:"+repeatHex("d"))
	build := completeTestBuild(ir.Node{ID: "build-cancel", Kind: ir.KindBuild, Component: "cancel", Toolchain: toolchain}, fetch)
	graph := testSourceGraph(fetch, build)
	digest := mustGraphDigest(t, graph)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	var output bytes.Buffer
	started := time.Now()
	_, err := (Local{}).Run(graph, digest, RunOptions{
		Ctx: ctx, SourceRoot: filepath.Join(t.TempDir(), "work", "src"), Stdout: &output,
	})
	if code(err) != nvkrerr.CodeTimeout {
		t.Fatalf("canceled fetch returned %v", err)
	}
	if !strings.Contains(output.String(), "[start] fetch") {
		t.Fatalf("slow fetch was silent until completion: %q", output.String())
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("git fetch ignored cancellation for %s", elapsed)
	}
}

func TestLocalDryRunKeepsLifecycleProgressQuiet(t *testing.T) {
	toolchain := "registry.example/toolchain@sha256:" + repeatHex("c")
	fetch := testFetchNode("fetch-plan", "https://example.test/source", testSourceCommit, testSourceTree,
		"source", toolchain, "sha256:"+repeatHex("d"))
	build := completeTestBuild(ir.Node{ID: "build-plan", Kind: ir.KindBuild, Component: "plan", Toolchain: toolchain}, fetch)
	graph := testSourceGraph(fetch, build)
	digest := mustGraphDigest(t, graph)
	var output bytes.Buffer
	if _, err := (Local{}).Run(graph, digest, RunOptions{
		Ctx: context.Background(), DryRun: true, Stdout: &output,
	}); err != nil {
		t.Fatal(err)
	}
	for _, noisy := range []string{"[start]", "[container]", "[source]", "[done]"} {
		if strings.Contains(output.String(), noisy) {
			t.Fatalf("dry-run plan contains live lifecycle marker %q: %s", noisy, output.String())
		}
	}
}

func TestMapCancellationPreservesRetryableTimeoutContract(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := mapCancellation(ctx, nvkrerr.New(nvkrerr.CodeBuildFailed, "semantic wrapper"), "build")
	if code(err) != nvkrerr.CodeTimeout || !nvkrerr.Retryable(err) {
		t.Fatalf("cancellation was not retained as a retryable timeout: %v", err)
	}
}

func code(err error) nvkrerr.Code {
	var e *nvkrerr.Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

func TestErrorCodeMatchesPublicExitStatusThroughWrapping(t *testing.T) {
	primary := nvkrerr.New(nvkrerr.CodeBuildFailed, "build failed")
	secondary := nvkrerr.New(nvkrerr.CodeVerifyFailed, "log collection failed")
	for _, test := range []struct {
		name string
		err  error
		want nvkrerr.Code
		exit int
	}{
		{name: "nil", exit: 0},
		{name: "uncoded", err: errors.New("uncoded"), exit: 1},
		{name: "direct", err: primary, want: nvkrerr.CodeBuildFailed, exit: 21},
		{name: "wrapped", err: fmt.Errorf("outer: %w", primary), want: nvkrerr.CodeBuildFailed, exit: 21},
		{name: "joined nil", err: errors.Join(primary, nil), want: nvkrerr.CodeBuildFailed, exit: 21},
		{name: "joined secondary", err: errors.Join(primary, secondary), want: nvkrerr.CodeBuildFailed, exit: 21},
		{name: "nested join", err: errors.Join(errors.Join(primary, secondary), context.Canceled), want: nvkrerr.CodeBuildFailed, exit: 21},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := code(test.err); got != test.want {
				t.Fatalf("code(%v) = %q, want %q", test.err, got, test.want)
			}
			if got := nvkrerr.ExitCode(test.err); got != test.exit {
				t.Fatalf("ExitCode(%v) = %d, want %d", test.err, got, test.exit)
			}
		})
	}
}

func TestQualifiedPackagingFailsBeforeGraphOrPathIO(t *testing.T) {
	missingRoot := filepath.Join(t.TempDir(), "must-remain-missing")
	_, err := (Local{}).Run(nil, "", RunOptions{
		Ctx: context.Background(), SourceRoot: missingRoot, Package: true,
		Qualification: &QualifiedExecution{},
	})
	if code(err) != nvkrerr.CodeEngineCapability {
		t.Fatalf("qualified packaging error = %v, want engine-capability", err)
	}
	if _, statErr := os.Stat(missingRoot); !os.IsNotExist(statErr) {
		t.Fatalf("unsupported qualified packaging touched its source root: %v", statErr)
	}
}

func TestLocalVendorArgsUseNonRootAndWorkspaceParent(t *testing.T) {
	node := ir.Node{
		VendorImage: "registry.example/vendor@sha256:" + repeatHex("a"),
		VendorCmd:   []string{"bash", "-ec", "echo ok"},
	}
	dockerArgs := localVendorArgs("nvkr-vendor-test", node, "docker", "/work/.nvkr-vendor-1", "/work/source")
	wantUser := fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())
	for _, want := range []string{
		"--user", wantUser,
		"/work/.nvkr-vendor-1:/src",
		"/work/source:/src/source",
		"/src/source",
		"HOME=/src/.home",
		"TMPDIR=/src/.tmp",
		"GOCACHE=/src/.gocache",
		"GOPATH=/src/.go",
		"GOMODCACHE=/src/.gomod",
	} {
		if !slices.Contains(dockerArgs, want) {
			t.Fatalf("docker vendor args missing %q: %v", want, dockerArgs)
		}
	}
	for _, arg := range dockerArgs {
		if strings.Contains(arg, "/root") || arg == "/work/source:/src" {
			t.Fatalf("docker vendor args used forbidden root path %q: %v", arg, dockerArgs)
		}
	}
	podmanArgs := localVendorArgs("nvkr-vendor-test", node, "podman", "/work/.nvkr-vendor-1", "/work/source")
	if !slices.Contains(podmanArgs, "0:0") {
		t.Fatalf("podman vendor args missing rootless mapping 0:0: %v", podmanArgs)
	}
}

func TestLocalBuildContainerArgsUseNonRootAndScratchDefaults(t *testing.T) {
	args := localBuildContainerArgs("docker", "/work/.nvkr-build-1", []ir.EnvVar{
		{Name: "HOME", Value: "/custom/home"},
	})
	wantUser := fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())
	for _, want := range []string{
		"--user", wantUser,
		"/work/.nvkr-build-1:" + buildScratchContainerRoot,
		"TMPDIR=" + buildScratchContainerRoot + "/tmp",
		"GOCACHE=" + buildScratchContainerRoot + "/go-build",
		"GOPATH=" + buildScratchContainerRoot + "/go-path",
		"GOMODCACHE=" + buildScratchContainerRoot + "/go-mod",
	} {
		if !slices.Contains(args, want) {
			t.Fatalf("build args missing %q: %v", want, args)
		}
	}
	if slices.Contains(args, "HOME="+buildScratchContainerRoot+"/home") {
		t.Fatalf("build args overrode explicit HOME in node env: %v", args)
	}
}

func TestLocalVendorMaterializesNonRootScratchAndCleansUp(t *testing.T) {
	node, dir, opts := pristineClosureFixture(t)
	node.VendorImage = "registry.example/vendor@sha256:" + repeatHex("b")
	node.VendorCmd = []string{"vendor-step"}
	record := filepath.Join(t.TempDir(), "runtime.args")
	fakeRuntime := filepath.Join(t.TempDir(), "docker")
	script := fmt.Sprintf("#!/usr/bin/env bash\nset -eu\nprintf '%%s\\n' \"$@\" > %q\nprintf 'vendored' > %q\n",
		record, filepath.Join(dir, "vendored"))
	if err := os.WriteFile(fakeRuntime, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	opts.Runtime = fakeRuntime
	opts.Stdout = &bytes.Buffer{}
	opts.reap = newReaper(t.Context(), fakeRuntime)
	defer opts.reap.close()
	if err := (Local{}).vendor(node, dir, opts); err != nil {
		t.Fatalf("Local.vendor failed: %v", err)
	}
	raw, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if !slices.Contains(args, fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())) {
		t.Fatalf("vendor runtime did not pass non-root user: %v", args)
	}
	if !slices.Contains(args, "/src/source") {
		t.Fatalf("vendor runtime did not set workdir /src/source: %v", args)
	}
	entries, err := os.ReadDir(filepath.Dir(dir))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".nvkr-vendor-") {
			t.Fatalf("vendor scratch directory was not cleaned up: %s", entry.Name())
		}
	}
}
