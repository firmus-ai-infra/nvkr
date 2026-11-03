#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Boot the finished Ubuntu 24 AMD64 QCOW2 with NVKE's boot-smoke.sh.
# The result is a diagnostic guest boot. It does not authenticate the
# toolchain or the disk, and it does not qualify the Run.

set -euo pipefail

if [[ -z "${CIRCLE_BUILD_NUM:-}" ]]; then
  echo "CIRCLE_BUILD_NUM is required for the attempt name" >&2
  exit 1
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "boot smoke requires Linux, found $(uname -s)" >&2
  exit 1
fi

attempt="circleci-${CIRCLE_BUILD_NUM}"
qcow=".nvkr/runs/${attempt}/outputs/nvke-node-image-ubuntu24-amd64.qcow2"
plan=".nvkr/runs/${attempt}/.runner/plan.json"
nvke=".nvkr/nvke-efi-src"
smoke="${nvke}/os-image/packer/scripts/boot-smoke.sh"
log_dir=".nvkr/evidence"
log="${log_dir}/boot-smoke-amd64.log"

[[ -f "${qcow}" ]] || { echo "missing built disk ${qcow}" >&2; exit 1; }
[[ -f "${plan}" ]] || { echo "missing executable Plan ${plan}" >&2; exit 1; }
[[ -f "${smoke}" ]] || { echo "missing NVKE boot-smoke.sh at ${smoke}" >&2; exit 1; }
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || { echo "boot smoke needs read/write access to /dev/kvm" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

if ! image="$(jq -er '
  [.builds[].executionGraph.nodes[] |
    select(.kind == "build" and .builderType == "vm-image") | .toolchain] |
  if length == 1 then .[0] else error("expected exactly one disk toolchain") end
' "${plan}")"; then
  echo "executable Plan must identify exactly one vm-image toolchain" >&2
  exit 1
fi
[[ "${image}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Plan toolchain is not a sha256 image ID" >&2; exit 1; }
observed="$(docker image inspect --format '{{.Id}}' "${image}")" || {
  echo "Plan toolchain image is not available locally" >&2
  exit 1
}
[[ "${observed}" == "${image}" ]] || { echo "observed toolchain image does not match the Plan" >&2; exit 1; }

mkdir -p "${log_dir}" ".nvkr/boot-smoke/amd64"
identity_dir="${PWD}/.nvkr/boot-smoke-identity/amd64"
install -d -m 0700 "${identity_dir}"
printf 'nvkr:x:%s:%s:NVKR Builder:/work:/bin/sh\n' "$(id -u)" "$(id -g)" >"${identity_dir}/passwd"
printf 'nvkr:x:%s:\n' "$(id -g)" >"${identity_dir}/group"
chmod 0400 "${identity_dir}/passwd" "${identity_dir}/group"
kvm_group="$(stat -c %g /dev/kvm)"

docker run --rm --pull=never --network=none --read-only --cap-drop=all \
  --security-opt no-new-privileges --device /dev/kvm --group-add "${kvm_group}" \
  --userns=host \
  --user "$(id -u):$(id -g)" --tmpfs /tmp:rw,nosuid,nodev \
  --mount "type=bind,src=${identity_dir}/passwd,dst=/etc/passwd,readonly" \
  --mount "type=bind,src=${identity_dir}/group,dst=/etc/group,readonly" \
  --volume "${PWD}/${nvke}:/nvke:ro" \
  --volume "${PWD}/${qcow}:/nvke-node-image-ubuntu24-amd64.qcow2:ro" \
  --volume "${PWD}/.nvkr/boot-smoke/amd64:/work:rw" \
  --entrypoint bash "${image}" -ec '
    ssh-keygen -q -t ed25519 -N "" -f /work/id_ed25519
    QCOW=/nvke-node-image-ubuntu24-amd64.qcow2 SSH_KEY=/work/id_ed25519 REQUIRE_ACCELERATION=1 TMPDIR=/work \
      /nvke/os-image/packer/scripts/boot-smoke.sh
  ' 2>&1 | tee "${log}"
