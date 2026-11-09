#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Upload one Ubuntu 24.04.5 ARM64 node QCOW2 to RustFS with mc.
# S3_ACCESS_KEY and S3_SECRET_KEY come from the CircleCI nico-harbor context.
# The job sets S3_ENDPOINT, S3_BUCKET, and S3_PREFIX. This script does not
# create the bucket or change its access policy. Object names include the
# 12-character git short SHA, so a later upload of a different commit does not
# replace this disk.

set -euo pipefail

qcow="${1:?usage: scripts/push-node-image-s3.sh <qcow2>}"
name="nvke-node-image-ubuntu24-arm64"

: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_PREFIX:?S3_PREFIX is required}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY is required}"
: "${CIRCLE_SHA1:?CIRCLE_SHA1 is required}"

head="$(git rev-parse HEAD)"
short="$(git rev-parse --short=12 HEAD)"
if [[ -z "${CIRCLE_SHA1}" || "${CIRCLE_SHA1}" != "${head}" ]]; then
  echo "ERROR: CIRCLE_SHA1 does not match git HEAD" >&2
  exit 1
fi
if [[ ! "${short}" =~ ^[0-9a-f]{12}$ || "${head}" != "${short}"* ]]; then
  echo "ERROR: git short SHA ${short} does not match HEAD" >&2
  exit 1
fi
commit="${head}"
artifact="${name}-${short}"

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

digest="$(awk '{ print $1 }' "${sha}")"
case "${digest}" in
  *[!0-9a-f]*|"")
    echo "ERROR: disk checksum is not a hex digest" >&2
    exit 1
    ;;
esac
if [[ "${#digest}" -ne 64 ]]; then
  echo "ERROR: disk checksum is not a SHA-256 digest" >&2
  exit 1
fi
info_commit="$(awk -F': ' '$1 == "commit" { print $2; exit }' "${info}")"
info_artifact="$(awk -F': ' '$1 == "artifact" { print $2; exit }' "${info}")"
if [[ "${info_commit}" != "${commit}" ]]; then
  echo "ERROR: build-info commit ${info_commit:-missing} does not match git HEAD ${commit}" >&2
  exit 1
fi
if [[ "${info_artifact}" != "${artifact}.qcow2" ]]; then
  echo "ERROR: build-info artifact ${info_artifact:-missing} does not match ${artifact}.qcow2" >&2
  exit 1
fi

# The local file keeps the catalog output name. The published checksum names
# the commit-stamped object so sha256sum -c matches the S3 key.
published_sha="$(mktemp)"
alias_name="nvke-s3"
cleanup() {
  rm -f "${published_sha}"
  mc alias rm "${alias_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
printf '%s  %s\n' "${digest}" "${artifact}.qcow2" >"${published_sha}"
mc alias set "${alias_name}" "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" >/dev/null

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

upload "${qcow}" "${artifact}.qcow2"
upload "${published_sha}" "${artifact}.qcow2.sha256"
upload "${info}" "${artifact}.build-info.txt"
