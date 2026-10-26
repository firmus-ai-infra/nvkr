#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Push OCI layouts from one CircleCI attempt to Harbor.
# image pushes only that attempt's controller image.
# charts pushes that attempt's three charts and the controller image bound into controller-chart.
# Credentials come from the environment. This script does not print them.

set -euo pipefail

usage() {
  printf '%s\n' 'Usage: scripts/push-harbor-oci.sh image|charts ATTEMPT' >&2
  exit 2
}

if [[ $# -ne 2 ]]; then
  usage
fi

kind="$1"
attempt="$2"

case "${kind}" in
  image | charts) ;;
  *) usage ;;
esac

if [[ ! "${attempt}" =~ ^circleci-[0-9]+-(image|charts)$ ]]; then
  printf '%s\n' 'ERROR: attempt must be circleci-<build>-image or circleci-<build>-charts' >&2
  exit 1
fi
if [[ "${kind}" == image && "${attempt}" != *-image ]]; then
  printf '%s\n' 'ERROR: image push requires an image attempt' >&2
  exit 1
fi
if [[ "${kind}" == charts && "${attempt}" != *-charts ]]; then
  printf '%s\n' 'ERROR: chart push requires a charts attempt' >&2
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  printf '%s\n' 'ERROR: these Harbor outputs are linux/amd64' >&2
  exit 1
fi

: "${HARBOR_HOST:?HARBOR_HOST is required}"
: "${HARBOR_USER:?HARBOR_USER is required}"
: "${HARBOR_PASS:?HARBOR_PASS is required}"
: "${IMAGE_REGISTRY:?IMAGE_REGISTRY is required}"
: "${CHART_REGISTRY:?CHART_REGISTRY is required}"

case "${HARBOR_HOST}" in
  harbor.cbr01.in.firmus.co) ;;
  *)
    printf '%s\n' 'ERROR: HARBOR_HOST must be harbor.cbr01.in.firmus.co' >&2
    exit 1
    ;;
esac
case "${IMAGE_REGISTRY}" in
  harbor.cbr01.in.firmus.co/nvke) ;;
  *)
    printf '%s\n' 'ERROR: IMAGE_REGISTRY must be harbor.cbr01.in.firmus.co/nvke' >&2
    exit 1
    ;;
esac
case "${CHART_REGISTRY}" in
  harbor.cbr01.in.firmus.co/nvke/charts) ;;
  *)
    printf '%s\n' 'ERROR: CHART_REGISTRY must be harbor.cbr01.in.firmus.co/nvke/charts' >&2
    exit 1
    ;;
esac

command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: python3 is required to read the OCI index' >&2
  exit 1
}

oras_version="1.3.3"
oras_archive_digest="9ce999f8d2de03fc03968b29d743077a58783e545e5eaa53917ca177352d0e59"
oras_root="${TMPDIR:-/tmp}/nvkr-oras-${oras_version}"
oras_bin="${oras_root}/oras"
if [[ ! -x "${oras_bin}" ]]; then
  mkdir -p "${oras_root}"
  archive="${oras_root}/oras.tar.gz"
  curl -fsSL -o "${archive}" \
    "https://github.com/oras-project/oras/releases/download/v${oras_version}/oras_${oras_version}_linux_amd64.tar.gz"
  echo "${oras_archive_digest}  ${archive}" | sha256sum -c -
  tar -C "${oras_root}" -xzf "${archive}" oras
  rm -f "${archive}"
  test -x "${oras_bin}"
fi

config_dir="$(mktemp -d "${TMPDIR:-/tmp}/nvkr-harbor.XXXXXX")"
cleanup() {
  rm -rf "${config_dir}"
}
trap cleanup EXIT

printf '%s\n' "${HARBOR_PASS}" | "${oras_bin}" login "${HARBOR_HOST}" \
  --username "${HARBOR_USER}" \
  --password-stdin \
  --registry-config "${config_dir}/config.json" >/dev/null

layout_digest() {
  local layout="$1"
  test -f "${layout}/oci-layout"
  test -f "${layout}/index.json"
  python3 -c 'import json, re, sys
idx = json.load(open(sys.argv[1], encoding="utf-8"))
manifests = idx.get("manifests")
if not isinstance(manifests, list) or len(manifests) != 1:
    sys.exit("ERROR: OCI index must contain exactly one manifest")
digest = manifests[0].get("digest", "")
if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    sys.exit("ERROR: OCI manifest digest is not sha256")
print(digest)' "${layout}/index.json"
}

push_layout() {
  local name="$1"
  local repository="$2"
  local layout=".nvkr/runs/${attempt}/packages/${name}"
  local digest dest
  digest="$(layout_digest "${layout}")"
  dest="${repository}/${name}:${attempt}"
  "${oras_bin}" cp --from-oci-layout "${layout}@${digest}" "${dest}" \
    --to-registry-config "${config_dir}/config.json"
  printf 'pushed %s\n' "${dest}"
}

case "${kind}" in
  image)
    push_layout cwe "${IMAGE_REGISTRY}"
    ;;
  charts)
    push_layout cwe "${IMAGE_REGISTRY}"
    push_layout controller-chart "${CHART_REGISTRY}"
    push_layout nktp "${CHART_REGISTRY}"
    push_layout ovn-kubernetes-chart "${CHART_REGISTRY}"
    ;;
esac
