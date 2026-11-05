#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build NVKE's arm64 qcow-imager.efi inside a privileged, native arm64 Ubuntu
# container (Docker Desktop on Apple Silicon, or any arm64 Docker host).
#
# This adds no build logic. It runs NVKE's own `make -C os-image/efi` targets
# (setup-host, check-deps, build-efi-arm64), which pin NVIDIA/infra-controller by
# commit. The container only supplies the Linux namespaces mkosi needs.
#
# The result is an unattested local build. It is not proven to boot or image a
# node until an iPXE boot of the target machine has done so.
#
# Usage: scripts/build-efi-docker.sh
# Environment:
#   NVKE_DIR       NVKE checkout holding os-image/efi (default ~/Dev/nvke)
#   EFI_OUT_DIR    host output directory (default <repo>/.nvkr/efi-out)
#   EFI_VOLUME     Docker volume for the checkout and caches (default nvke-efi-work)
#   EFI_MIN_MEM_GIB  minimum Docker memory in GiB (default 8)
#   EFI_FORCE      set to 1 to overwrite an existing output file
#
# Fails closed: every precondition is checked before any long-running work.

set -euo pipefail

# ubuntu:24.04 (linux/arm64 index), pinned by digest.
readonly BASE_IMAGE="ubuntu@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nvke_dir="${NVKE_DIR:-${HOME}/Dev/nvke}"
out_dir="${EFI_OUT_DIR:-${repo_root}/.nvkr/efi-out}"
volume="${EFI_VOLUME:-nvke-efi-work}"
min_mem_gib="${EFI_MIN_MEM_GIB:-8}"
container="nvke-efi-build"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "${min_mem_gib}" =~ ^[1-9][0-9]*$ ]] || die "EFI_MIN_MEM_GIB must be a positive integer"
command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
[[ -f "${nvke_dir}/os-image/efi/Makefile" ]] || die "no os-image/efi/Makefile under NVKE_DIR=${nvke_dir}"

if ! info="$(docker info --format '{{.NCPU}} {{.MemTotal}} {{.Architecture}}' 2>&1)"; then
  die "cannot reach the Docker daemon: ${info}"
fi
read -r ncpu mem_bytes docker_arch <<<"${info}"
case "${docker_arch}" in
  aarch64 | arm64) ;;
  *) die "Docker server architecture is ${docker_arch}; this build needs a native aarch64 daemon (emulated builds are not supported here)" ;;
esac
if ((mem_bytes < min_mem_gib * 1024 * 1024 * 1024)); then
  die "Docker has $((mem_bytes / 1024 / 1024 / 1024)) GiB memory; raise it to at least ${min_mem_gib} GiB"
fi
echo "Docker: ${ncpu} CPUs, $((mem_bytes / 1024 / 1024 / 1024)) GiB, ${docker_arch}"

mkdir -p "${out_dir}"
efi_out="${out_dir}/qcow-imager.efi"
if [[ -e "${efi_out}" && "${EFI_FORCE:-0}" != "1" ]]; then
  die "${efi_out} exists; set EFI_FORCE=1 to overwrite"
fi

# Namespace smoke test: the go/no-go for mkosi. Runs in seconds, before the build.
echo "=== Namespace smoke test ==="
docker run --rm --privileged --platform linux/arm64 "${BASE_IMAGE}" bash -c '
  set -e
  [ "$(uname -m)" = aarch64 ]
  [ "$(id -u)" = 0 ]
  unshare -m true
  unshare -U -r true
  unshare -p -f --mount-proc true
  mkdir -p /tmp/t && mount -t tmpfs tmpfs /tmp/t
' </dev/null || die "container cannot create namespaces or mounts; see the fallbacks in the plan"
echo "smoke test ok"

# Runs inside the container as root. HOME lives on the volume so rustup,
# cargo-make and the mkosi cache survive between runs.
inner="$(
  cat <<'INNER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME=/work/home
mkdir -p "${HOME}" /work/efi

echo "=== Bootstrap packages ==="
apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl file git make pkg-config libssl-dev sudo

echo "=== Copy os-image/efi into the volume ==="
# Keep .infra-controller (mkosi cache) and output on the volume across runs.
tar -C /src --exclude=./.infra-controller --exclude=./output -cf - . | tar -C /work/efi -xf -

echo "=== make setup-host ==="
make -C /work/efi setup-host

export PATH="${HOME}/.cargo/bin:${PATH}"
echo "=== make check-deps ==="
make -C /work/efi check-deps

echo "=== make build-efi-arm64 ==="
make -C /work/efi build-efi-arm64

efi=/work/efi/output/aarch64/qcow-imager.efi
[ -s "${efi}" ] || { echo "ERROR: ${efi} is missing or empty" >&2; exit 1; }
file -b "${efi}" | grep -qi 'EFI application' || { echo "ERROR: not an EFI application: $(file -b "${efi}")" >&2; exit 1; }
file -b "${efi}" | grep -qiE 'aarch64|ARM64' || { echo "ERROR: not an ARM64 binary: $(file -b "${efi}")" >&2; exit 1; }
cp "${efi}" /out/qcow-imager.efi
sha256sum /out/qcow-imager.efi | sed 's# /out/# #' >/out/qcow-imager.efi.sha256
file -b "${efi}" >/out/qcow-imager.efi.file.txt
echo "=== Done ==="
cat /out/qcow-imager.efi.sha256 /out/qcow-imager.efi.file.txt
INNER
)"

docker volume create "${volume}" >/dev/null
docker rm -f "${container}" >/dev/null 2>&1 || true

echo "=== Building in container ${container} (log: ${out_dir}/build.log) ==="
rm -f "${efi_out}"
docker run --name "${container}" --rm --privileged --platform linux/arm64 \
  -v "${nvke_dir}/os-image/efi:/src:ro" \
  -v "${volume}:/work" \
  -v "${out_dir}:/out" \
  "${BASE_IMAGE}" bash -c "${inner}" </dev/null 2>&1 | tee "${out_dir}/build.log"

[[ -s "${efi_out}" ]] || die "build finished without ${efi_out}; see ${out_dir}/build.log"
echo "Output: ${efi_out}"
