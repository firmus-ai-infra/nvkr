#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Download the four NVKE v0.22.0 charts that the catalog acquires instead of building.
# Digests are the amd64 and arm64 entries in inputs/catalogs/nvke/release/pins.lock.yaml,
# derived from nvke@400c24fb6465b042be883d6b62472528520d6291.
# This script does not build charts and does not push them to Harbor.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf '%s\n' 'Usage: scripts/pull-external-nvke-charts.sh DESTINATION' >&2
  exit 2
fi

dest="$1"
if [[ -e "${dest}" ]]; then
  printf '%s\n' "ERROR: destination already exists: ${dest}" >&2
  exit 1
fi
mkdir -p "${dest}"

command -v curl >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: curl is required' >&2
  exit 1
}
command -v sha256sum >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: sha256sum is required' >&2
  exit 1
}
command -v helm >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: helm is required to pull the Bitnami postgresql chart' >&2
  exit 1
}

pull_file() {
  local name="$1"
  local url="$2"
  local digest="$3"
  curl -fsSL -o "${dest}/${name}" "${url}"
  echo "${digest}  ${dest}/${name}" | sha256sum -c -
  printf 'verified %s\n' "${name}"
}

helm pull oci://registry-1.docker.io/bitnamicharts/postgresql \
  --version 18.5.15 \
  --destination "${dest}"
echo "c350143d2e21c1e1a3670dd32ab64fd11d49198a66fae87c63a3112531c0cd17  ${dest}/postgresql-18.5.15.tgz" \
  | sha256sum -c -
printf '%s\n' 'verified postgresql-18.5.15.tgz'

pull_file spire-0.30.1.tgz \
  https://github.com/spiffe/helm-charts-hardened/releases/download/spire-0.30.1/spire-0.30.1.tgz \
  7c32126bb1909076cdf9fd0419dbf9e5b012f152bb09a96a4259917d70581fac
pull_file spire-crds-0.6.1.tgz \
  https://github.com/spiffe/helm-charts-hardened/releases/download/spire-crds-0.6.1/spire-crds-0.6.1.tgz \
  ce982e63fc375e392b014fc99e621a55442ab886052413e9bb052f72d66580a8
pull_file temporal-0.74.0.tgz \
  https://github.com/temporalio/helm-charts/releases/download/temporal-0.74.0/temporal-0.74.0.tgz \
  14a8efe1cc92c91befac151db91f20f9a13962788e9d710c86655add6d966d37
