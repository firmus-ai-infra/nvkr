#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Fetch the pinned NVKE commit that owns boot-smoke.sh.
# A checkout already at that commit is left in place. Any other tree is an error.

set -euo pipefail

nvke_repo="https://github.com/firmus-ai-infra/nvke.git"
nvke_commit="2c8c9b8f80fcd94009ff79d50710931675a73e67"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
src="${repo_root}/.nvkr/nvke-efi-src"
smoke="${src}/os-image/packer/scripts/boot-smoke.sh"

command -v git >/dev/null 2>&1 || { echo "ERROR: git is required." >&2; exit 1; }

if [[ -f "${smoke}" ]]; then
  head="$(git -C "${src}" rev-parse HEAD)"
  if [[ "${head}" == "${nvke_commit}" ]]; then
    exit 0
  fi
  echo "ERROR: ${src} is ${head}, not ${nvke_commit}." >&2
  exit 1
fi
if [[ -e "${src}" ]]; then
  echo "ERROR: ${src} already exists." >&2
  exit 1
fi

mkdir -p "${src}"
git -C "${src}" init -q
git -C "${src}" remote add origin "${nvke_repo}"
GIT_TERMINAL_PROMPT=0 git -C "${src}" fetch --depth 1 origin "${nvke_commit}"
git -C "${src}" checkout -q --detach FETCH_HEAD

if [[ ! -f "${smoke}" ]]; then
  echo "ERROR: pinned NVKE checkout has no ${smoke}." >&2
  exit 1
fi
