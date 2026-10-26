#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Upload one Ubuntu 24.04.5 AMD64 node QCOW2 to RustFS with mc.
# S3_ACCESS_KEY and S3_SECRET_KEY come from the CircleCI nico-harbor context.
# The job sets S3_ENDPOINT, S3_BUCKET, and S3_PREFIX. This script does not
# create the bucket or change its access policy. The three object names are
# stable, so a later upload replaces them.

set -euo pipefail

qcow="${1:?usage: scripts/push-node-image-s3.sh <qcow2>}"
name="nvke-node-image-ubuntu24-amd64"

: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_PREFIX:?S3_PREFIX is required}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY is required}"

case "${S3_ENDPOINT}" in
  https://s3-console.cbr01.in.firmus.co|https://s3-console.cbr01.in.firmus.co/) ;;
  *)
    echo "ERROR: S3_ENDPOINT must be https://s3-console.cbr01.in.firmus.co/" >&2
    exit 1
    ;;
esac
if [[ "${S3_BUCKET}" != "nvke" || "${S3_PREFIX}" != "${name}" ]]; then
  echo "ERROR: S3_BUCKET must be nvke and S3_PREFIX must be ${name}" >&2
  exit 1
fi
if [[ "$(basename "${qcow}")" != "${name}.qcow2" ]]; then
  echo "ERROR: expected ${name}.qcow2, found $(basename "${qcow}")" >&2
  exit 1
fi

command -v mc >/dev/null 2>&1 || {
  echo "ERROR: mc (minio client) not found." >&2
  exit 1
}

outdir="$(dirname "${qcow}")"
sha="${qcow}.sha256"
info="${outdir}/build-info.txt"
for f in "${qcow}" "${sha}" "${info}"; do
  [[ -f "${f}" ]] || {
    echo "ERROR: missing ${f}" >&2
    exit 1
  }
done

alias_name="nvke-s3"
mc alias set "${alias_name}" "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" >/dev/null
trap 'mc alias rm "${alias_name}" >/dev/null 2>&1 || true' EXIT

mc ls "${alias_name}/${S3_BUCKET}" >/dev/null 2>&1 || {
  echo "ERROR: bucket '${S3_BUCKET}' does not exist on ${S3_ENDPOINT}." >&2
  exit 1
}

upload() {
  local src="$1"
  local dest_name="$2"
  echo "  upload -> ${S3_BUCKET}/${S3_PREFIX}/${dest_name}"
  mc cp --quiet "${src}" "${alias_name}/${S3_BUCKET}/${S3_PREFIX}/${dest_name}" >/dev/null
}

upload "${qcow}" "${name}.qcow2"
upload "${sha}" "${name}.qcow2.sha256"
upload "${info}" "${name}.build-info.txt"
