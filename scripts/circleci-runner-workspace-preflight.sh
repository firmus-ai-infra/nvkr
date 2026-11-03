#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Repair the retained NVKR workspace before CircleCI starts a task. Install and
# invoke this script from the runner host's task-launch hook, not from a job:
# CircleCI must remove its workdir before it can execute .circleci/config.yml.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: circleci-runner-workspace-preflight.sh --workspace ABSOLUTE_PATH --owner UID:GID

Requires root. Reassigns only directories in an existing .nvkr subtree to the
runner identity and ensures that identity can traverse and modify them. It
never deletes or changes ownership of files and refuses a symlinked or root
workspace.
EOF
}

workspace=""
owner=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --owner)
      owner="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "workspace preflight must run as root" >&2
  exit 1
fi
if [[ ! "${owner}" =~ ^[0-9]+:[0-9]+$ ]]; then
  echo "--owner must be a numeric UID:GID" >&2
  exit 2
fi
case "${workspace}" in
  /*) ;;
  *)
    echo "--workspace must be an absolute path" >&2
    exit 2
    ;;
esac

workspace="$(realpath -e -- "${workspace}")"
if [[ "${workspace}" == "/" || ! -d "${workspace}" || -L "${workspace}" ]]; then
  echo "--workspace must name an existing, non-symlink directory below /" >&2
  exit 2
fi
target="${workspace}/.nvkr"
if [[ ! -e "${target}" ]]; then
  exit 0
fi
if [[ ! -d "${target}" || -L "${target}" ]]; then
  echo "refusing non-directory or symlinked NVKR state: ${target}" >&2
  exit 1
fi
target="$(realpath -e -- "${target}")"
case "${target}" in
  "${workspace}"/*) ;;
  *)
    echo "refusing NVKR state outside the requested workspace" >&2
    exit 1
    ;;
esac

uid="${owner%%:*}"
gid="${owner#*:}"
find -P "${target}" -xdev -type d -exec chown -h "${owner}" {} +
find -P "${target}" -xdev -type d -exec chmod u+rwx {} +

unowned="$(find -P "${target}" -xdev -type d \( ! -uid "${uid}" -o ! -gid "${gid}" \) -print -quit)"
if [[ -n "${unowned}" ]]; then
  printf 'workspace preflight left mismatched ownership: %s\n' "${unowned}" >&2
  exit 1
fi
inaccessible="$(find -P "${target}" -xdev -type d ! -perm -u=rwx -print -quit)"
if [[ -n "${inaccessible}" ]]; then
  printf 'workspace preflight left inaccessible directory: %s\n' "${inaccessible}" >&2
  exit 1
fi
