// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package pipeline

import (
	"fmt"
	"os"
	"slices"
	"testing"
)

func TestLocalBuildUserArgsUsesInvokingIdentity(t *testing.T) {
	args := localBuildUserArgs()
	want := []string{"--userns=host", "--user", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())}
	if !slices.Equal(args, want) {
		t.Fatalf("local build identity arguments = %#v, want %#v", args, want)
	}
}

func TestLocalBuildCacheArgsMatchVendorContainer(t *testing.T) {
	mounts := localBuildCacheMountArgs()
	wantMounts := []string{"--tmpfs", "/tmp:rw,nosuid,nodev,mode=1777"}
	if !slices.Equal(mounts, wantMounts) {
		t.Fatalf("local build cache mount = %#v, want %#v", mounts, wantMounts)
	}
	env := localBuildCacheEnvArgs()
	wantEnv := []string{
		"-e", "HOME=/tmp/home",
		"-e", "TMPDIR=/tmp",
		"-e", "GOCACHE=/tmp/go-build",
		"-e", "GOPATH=/tmp/go",
		"-e", "GOMODCACHE=/tmp/go/pkg/mod",
	}
	if !slices.Equal(env, wantEnv) {
		t.Fatalf("local build cache environment = %#v, want %#v", env, wantEnv)
	}
}
