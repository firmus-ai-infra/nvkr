// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package pipeline

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestLocalVendorArgsReturnOwnershipToInvokingAccount(t *testing.T) {
	command := []string{"bash", "-ec", "cd agent && go mod vendor"}
	args := localVendorArgs("nvkr-1-2-vendor-src", "/work/src/agent", "toolchain@sha256:abc", command)
	want := []string{
		"run", "--rm", "--name", "nvkr-1-2-vendor-src", "--network=default", "--userns=host",
		"-v", "/work/src/agent:/src", "-w", "/src", "toolchain@sha256:abc",
		"sh", "-c", localVendorOwnershipScript, "nvkr-vendor", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()),
		"bash", "-ec", "cd agent && go mod vendor",
	}
	if !slices.Equal(args, want) {
		t.Fatalf("vendor arguments = %#v, want %#v", args, want)
	}
}

func TestLocalVendorOwnershipScriptAlwaysReclaimsSource(t *testing.T) {
	tests := []struct {
		name        string
		command     []string
		chownStatus string
		wantStatus  int
	}{
		{name: "vendor succeeds", command: []string{"true"}, chownStatus: "0", wantStatus: 0},
		{name: "vendor failure keeps its status", command: []string{"sh", "-c", "exit 7"}, chownStatus: "0", wantStatus: 7},
		{name: "ownership failure fails closed", command: []string{"true"}, chownStatus: "3", wantStatus: 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			bin := t.TempDir()
			log := filepath.Join(t.TempDir(), "chown.log")
			stub := "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$CHOWN_LOG\"\nexit \"$CHOWN_STATUS\"\n"
			if err := os.WriteFile(filepath.Join(bin, "chown"), []byte(stub), 0o755); err != nil {
				t.Fatal(err)
			}
			args := append([]string{"-c", localVendorOwnershipScript, "nvkr-vendor", "1000:1000"}, tt.command...)
			cmd := exec.CommandContext(t.Context(), "/bin/sh", args...)
			cmd.Env = []string{
				"PATH=" + bin + string(os.PathListSeparator) + "/usr/bin:/bin",
				"CHOWN_LOG=" + log,
				"CHOWN_STATUS=" + tt.chownStatus,
			}
			status := 0
			if err := cmd.Run(); err != nil {
				var exit *exec.ExitError
				if !errors.As(err, &exit) {
					t.Fatalf("running ownership script: %v", err)
				}
				status = exit.ExitCode()
			}
			if status != tt.wantStatus {
				t.Fatalf("exit status = %d, want %d", status, tt.wantStatus)
			}
			recorded, err := os.ReadFile(log)
			if err != nil {
				t.Fatalf("chown was not invoked: %v", err)
			}
			if got := strings.TrimSpace(string(recorded)); got != "-R -h 1000:1000 /src" {
				t.Fatalf("chown arguments = %q, want %q", got, "-R -h 1000:1000 /src")
			}
		})
	}
}
