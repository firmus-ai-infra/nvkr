#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build qcow-imager.efi from the pinned NVKE checkout and upload it beside the
# Ubuntu 24 AMD64 node disk. S3_ACCESS_KEY and S3_SECRET_KEY come from the
# CircleCI nico-harbor context. The script does not print them.

set -euo pipefail

efi_name="qcow-imager.efi"

: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_PREFIX:?S3_PREFIX is required}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY is required}"

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
  echo "ERROR: qcow-imager.efi builds on Linux x86_64, found $(uname -s)/$(uname -m)." >&2
  exit 1
fi

case "${S3_ENDPOINT}" in
  https://s3-console.cbr01.in.firmus.co|https://s3-console.cbr01.in.firmus.co/) ;;
  *)
    echo "ERROR: S3_ENDPOINT must be https://s3-console.cbr01.in.firmus.co/" >&2
    exit 1
    ;;
esac
if [[ "${S3_BUCKET}" != "nvke" || "${S3_PREFIX}" != "nvke-node-image-ubuntu24-amd64" ]]; then
  echo "ERROR: S3_BUCKET must be nvke and S3_PREFIX must be nvke-node-image-ubuntu24-amd64" >&2
  exit 1
fi

command -v make >/dev/null 2>&1 || { echo "ERROR: make is required." >&2; exit 1; }
command -v file >/dev/null 2>&1 || { echo "ERROR: file is required." >&2; exit 1; }
command -v mc >/dev/null 2>&1 || { echo "ERROR: mc (minio client) not found." >&2; exit 1; }

"$(dirname "${BASH_SOURCE[0]}")/fetch-nvke-efi-src.sh"
src="${PWD}/.nvkr/nvke-efi-src"

# setup-host installs packages and changes host sysctls. The runner owner does
# that once. This job only checks the prepared host and builds.
export PATH="${HOME}/.cargo/bin:${PATH}"
make -C "${src}/os-image/efi" check-deps
make -C "${src}/os-image/efi" build-efi-x86

efi="${src}/os-image/efi/output/x86_64/${efi_name}"
if [[ ! -s "${efi}" ]]; then
  echo "ERROR: ${efi} is missing or empty." >&2
  exit 1
fi
described="$(file -b "${efi}")"
printf '%s\n' "${described}"
printf '%s\n' "${described}" | grep -qi 'PE32+ executable'
printf '%s\n' "${described}" | grep -qi 'EFI'
printf '%s\n' "${described}" | grep -qiE 'x86[-_]64'
sha256sum "${efi}" | tee "${efi}.sha256" >/dev/null
echo "  built ${efi_name}"

alias_name="nvke-s3"
mc alias set "${alias_name}" "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" >/dev/null
trap 'mc alias rm "${alias_name}" >/dev/null 2>&1 || true' EXIT
mc ls "${alias_name}/${S3_BUCKET}" >/dev/null 2>&1 || {
  echo "ERROR: bucket '${S3_BUCKET}' does not exist on ${S3_ENDPOINT}." >&2
  exit 1
}

echo "  upload -> ${S3_BUCKET}/${S3_PREFIX}/${efi_name}"
mc cp --quiet "${efi}" "${alias_name}/${S3_BUCKET}/${S3_PREFIX}/${efi_name}" >/dev/null
mc cp --quiet "${efi}.sha256" "${alias_name}/${S3_BUCKET}/${S3_PREFIX}/${efi_name}.sha256" >/dev/null
