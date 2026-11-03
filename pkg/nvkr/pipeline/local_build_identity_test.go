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
