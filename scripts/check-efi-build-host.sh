#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Preflight for building qcow-imager.efi (NVKE os-image/efi) on this host.
#
# It reads the host and changes nothing: no installs, no sysctl writes, no files
# other than the optional report. It does not stop at the first problem. Every
# check runs, then the script prints one numbered list of what must be done and
# exits 1 if that list is not empty. A clean run means only that the checks
# below passed, not that the EFI builds or boots.
#
# The requirements mirror os-image/efi/scripts/setup-efi-build-host.sh and the
# `check-deps` target in os-image/efi/Makefile (NVKE commit 8841a4d5). Items
# marked "unverified" are inferred and never fail the run.
#
# Usage: scripts/check-efi-build-host.sh
# Environment:
#   EFI_ARCH             arm64 (default) or amd64; the EFI architecture to build
#   EFI_MIN_FREE_GIB     free space required in the current directory (default 10)
#   EFI_CHECK_REPORT     also write the full output to this file
#   EFI_CHECK_SKIP_NET   set to 1 to skip the network reachability checks
#   EFI_CHECK_PROC_ROOT  procfs root to read sysctls from (default /proc; for tests)

# No `set -e`: the point is to run every check and report all failures together.
set -uo pipefail

arch="${EFI_ARCH:-arm64}"
min_free_gib="${EFI_MIN_FREE_GIB:-10}"
proc_root="${EFI_CHECK_PROC_ROOT:-/proc}" # overridable so tests can fake sysctl values

case "${arch}" in
  arm64) native_machine_re='^(aarch64|arm64)$' ;;
  amd64) native_machine_re='^x86_64$' ;;
  *) echo "EFI_ARCH must be arm64 or amd64" >&2; exit 2 ;;
esac
if [[ ! "${min_free_gib}" =~ ^[1-9][0-9]*$ ]]; then
  echo "EFI_MIN_FREE_GIB must be a positive integer" >&2
  exit 2
fi

# Same PATH addition the NVKE workflow makes, so a user-level cargo is found.
export PATH="${HOME:-/nonexistent}/.cargo/bin:${PATH}"

# Packages installed by setup-efi-build-host.sh.
packages=(apt-utils btrfs-progs bubblewrap cpio debian-archive-keyring debootstrap
  dosfstools e2fsprogs erofs-utils mtools python3-pefile qemu-utils squashfs-tools
  systemd-container systemd-ukify ubuntu-keyring uidmap xfsprogs xz-utils zstd)

act_scope=()
act_title=()
act_cmd=()
warnings=()

# add_action SCOPE TITLE COMMAND: SCOPE is "admin" (needs root) or "user".
add_action() {
  act_scope+=("$1")
  act_title+=("$2")
  act_cmd+=("$3")
}

ok() { printf '  ok       %s\n' "$*"; }
bad() { printf '  MISSING  %s\n' "$*"; }
warn() {
  warnings+=("$*")
  printf '  unverified %s\n' "$*"
}

# bounded SECONDS COMMAND...: run with a time limit when `timeout` exists.
bounded() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
  else
    "$@"
  fi
}

run_checks() {
  local host_os machine user uid i

  host_os="$(uname -s)"
  machine="$(uname -m)"
  uid="$(id -u)"
  user="$(id -un)"
  echo "== EFI build host check: target ${arch}, host ${host_os}/${machine}, user ${user} =="

  echo
  echo "-- Platform"
  if [[ "${host_os}" != Linux ]]; then
    bad "host is ${host_os}; mkosi needs Linux namespaces"
    add_action user "Run this build on Linux (Ubuntu or Debian). It cannot run on ${host_os}." \
      "use an Ubuntu 24.04 ${arch} Linux host or VM"
    echo "  Skipping the Linux-only checks."
    return
  fi
  ok "Linux"

  if [[ "${machine}" =~ ${native_machine_re} ]]; then
    ok "native ${arch} host"
  else
    warn "host is ${machine}, not ${arch}: the package install runs under qemu-user emulation and takes about twice as long"
    packages+=(binfmt-support qemu-user-static)
  fi

  if [[ "${uid}" == 0 ]]; then
    bad "running as root; the CircleCI job and this check expect a non-root account"
    add_action user "Run the build as a non-root user." "use the runner's normal user, not root"
  else
    ok "non-root user"
  fi

  echo
  echo "-- Packages and keyrings"
  local missing_pkgs=()
  if ! command -v apt-get >/dev/null 2>&1; then
    bad "apt-get not found; mkosi bootstraps Debian/Ubuntu roots with apt"
    add_action admin "Use a Debian or Ubuntu host (apt-get is required)." \
      "or translate the package list in os-image/efi/scripts/setup-efi-build-host.sh"
  elif ! command -v dpkg-query >/dev/null 2>&1; then
    bad "dpkg-query not found; cannot inspect installed packages"
    add_action admin "Use a Debian or Ubuntu host (dpkg-query is required)." "see above"
  else
    local pkg
    for pkg in "${packages[@]}"; do
      # shellcheck disable=SC2016 # ${Status} is a dpkg-query format, not a shell variable
      if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
        missing_pkgs+=("${pkg}")
      fi
    done
    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
      ok "all ${#packages[@]} packages installed"
    else
      bad "${#missing_pkgs[@]} of ${#packages[@]} packages not installed: ${missing_pkgs[*]}"
      add_action admin "Install ${#missing_pkgs[@]} missing packages." \
        "sudo apt-get update && sudo apt-get install -y ${missing_pkgs[*]}"
    fi
  fi

  local keyring pkg_for
  for keyring in debian-archive-keyring ubuntu-keyring; do
    pkg_for="${keyring}"
    if [[ ${#missing_pkgs[@]} -gt 0 && " ${missing_pkgs[*]} " == *" ${pkg_for} "* ]]; then
      continue # already covered by the install action
    fi
    if [[ -f "/usr/share/keyrings/${keyring}.gpg" ]]; then
      ok "/usr/share/keyrings/${keyring}.gpg"
    else
      bad "/usr/share/keyrings/${keyring}.gpg missing"
      add_action admin "Restore the ${keyring} keyring file." \
        "sudo apt-get install --reinstall -y ${pkg_for}"
    fi
  done

  echo
  echo "-- Unprivileged user namespaces (mkosi sandbox)"
  local sysctl_fix=()
  local key path val want
  for key in kernel.apparmor_restrict_unprivileged_userns \
    kernel.apparmor_restrict_unprivileged_unconfined \
    kernel.unprivileged_userns_clone; do
    path="${proc_root}/sys/$(printf '%s' "${key}" | tr . /)"
    want=0
    [[ "${key}" == kernel.unprivileged_userns_clone ]] && want=1
    if [[ ! -r "${path}" ]]; then
      ok "${key} not present on this kernel"
      continue
    fi
    val="$(<"${path}")"
    if [[ "${val}" == "${want}" ]]; then
      ok "${key}=${val}"
    else
      bad "${key}=${val}, needs ${want}"
      sysctl_fix+=("${key}=${want}")
    fi
  done
  if [[ -r "${proc_root}/sys/user/max_user_namespaces" ]]; then
    val="$(<"${proc_root}/sys/user/max_user_namespaces")"
    if [[ "${val}" =~ ^[0-9]+$ && "${val}" -gt 0 ]]; then
      ok "user.max_user_namespaces=${val}"
    else
      bad "user.max_user_namespaces=${val}, needs a value above 0"
      sysctl_fix+=("user.max_user_namespaces=15000")
    fi
  fi
  if [[ ${#sysctl_fix[@]} -gt 0 ]]; then
    add_action admin "Allow unprivileged user namespaces, and persist it so it survives a reboot." \
      "printf '%s\\n' ${sysctl_fix[*]} | sudo tee /etc/sysctl.d/60-nvke-efi-mkosi.conf >/dev/null && sudo sysctl --system"
  fi

  # Rootless mkosi maps sub-uids; uidmap is in the package list. Inferred, not tested.
  if [[ -r /etc/subuid && -r /etc/subgid ]]; then
    if grep -Eq "^(${user}|${uid}):" /etc/subuid && grep -Eq "^(${user}|${uid}):" /etc/subgid; then
      ok "subuid/subgid ranges for ${user}"
    else
      warn "no /etc/subuid or /etc/subgid range for ${user}; rootless mkosi probably needs one: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${user}"
    fi
  else
    warn "/etc/subuid or /etc/subgid unreadable; could not check sub-uid ranges for ${user}"
  fi

  echo
  echo "-- Tools"
  local tool
  for tool in git curl file sha256sum make; do
    if command -v "${tool}" >/dev/null 2>&1; then
      ok "${tool}"
    else
      bad "${tool} not found"
      case "${tool}" in
        sha256sum | make) add_action admin "Install ${tool}." "sudo apt-get install -y coreutils make" ;;
        *) add_action admin "Install ${tool}." "sudo apt-get install -y ${tool}" ;;
      esac
    fi
  done
  local need_cargo=0
  if command -v cargo >/dev/null 2>&1; then
    ok "cargo $(cargo --version 2>/dev/null | awk '{print $2}')"
    if cargo make --version >/dev/null 2>&1; then
      ok "cargo-make"
    else
      bad "cargo-make not installed (upstream build tasks are cargo-make tasks)"
      add_action user "Install cargo-make in the runner user's home (no sudo)." \
        "cargo install cargo-make --locked"
      need_cargo=1
    fi
  else
    bad "cargo not found"
    add_action user "Install the Rust toolchain and cargo-make in the runner user's home (no sudo)." \
      "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal && cargo install cargo-make --locked"
    need_cargo=1
  fi

  # `cargo install cargo-make` compiles from source and needs a C linker.
  if [[ ${need_cargo} -eq 1 ]]; then
    if command -v cc >/dev/null 2>&1; then
      ok "cc (C linker for cargo-make)"
    else
      bad "cc not found; installing cargo-make compiles it and needs a C linker"
      add_action admin "Install a C toolchain so cargo-make can build." "sudo apt-get install -y build-essential"
    fi
    warn "cargo-make may also need pkg-config and libssl-dev to compile; install them if 'cargo install cargo-make' fails"
  fi

  echo
  echo "-- Disk"
  local avail_kib
  avail_kib="$(df -Pk . 2>/dev/null | awk 'NR==2 { print $4 }')"
  if [[ ! "${avail_kib}" =~ ^[0-9]+$ ]]; then
    bad "could not read free space in $(pwd)"
    add_action user "Make the working directory's free space readable." "check 'df -Pk .'"
  elif [[ "${avail_kib}" -lt $((min_free_gib * 1024 * 1024)) ]]; then
    bad "$((avail_kib / 1024 / 1024)) GiB free in $(pwd), need ${min_free_gib} GiB"
    add_action user "Free at least ${min_free_gib} GiB in the working directory." "remove old attempts under .nvkr/ or use a larger volume"
  else
    ok "$((avail_kib / 1024 / 1024)) GiB free in $(pwd)"
  fi

  echo
  echo "-- Network"
  if [[ "${EFI_CHECK_SKIP_NET:-0}" == 1 ]]; then
    echo "  skipped (EFI_CHECK_SKIP_NET=1)"
  else
    if command -v git >/dev/null 2>&1; then
      if GIT_TERMINAL_PROMPT=0 bounded 60 git ls-remote --exit-code \
        https://github.com/NVIDIA/infra-controller.git HEAD >/dev/null 2>&1; then
        ok "github.com/NVIDIA/infra-controller reachable"
      else
        bad "cannot read https://github.com/NVIDIA/infra-controller.git (the pinned upstream build source)"
        add_action admin "Allow HTTPS egress to github.com, or set a proxy for the runner." \
          "check proxy and firewall; the build also fetches the pxe/mkosi submodule from GitHub"
      fi
    fi
    if command -v curl >/dev/null 2>&1; then
      local urls=("https://deb.debian.org/debian/dists/stable/Release")
      if [[ "${arch}" == arm64 ]]; then
        urls+=("http://ports.ubuntu.com/ubuntu-ports/dists/noble/Release")
      else
        urls+=("http://archive.ubuntu.com/ubuntu/dists/noble/Release")
      fi
      if [[ ${need_cargo} -eq 1 ]]; then
        urls+=("https://sh.rustup.rs" "https://index.crates.io/config.json")
      fi
      local url
      for url in "${urls[@]}"; do
        if curl -fsSI --max-time 15 -o /dev/null "${url}" 2>/dev/null; then
          ok "${url}"
        else
          warn "cannot reach ${url}; mkosi pulls Debian and Ubuntu packages from the default archives, so allow them or configure a mirror"
        fi
      done
    fi
  fi

  echo
  echo "-- Privilege"
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    ok "passwordless sudo available; 'make -C os-image/efi setup-host' can apply the administrator items"
  else
    warn "no passwordless sudo for ${user}; an administrator must apply the 'administrator' items below"
  fi
}

report_actions() {
  local n=${#act_scope[@]} i count=0 scope label
  echo
  if [[ ${n} -eq 0 ]]; then
    echo "== No required actions. The checks above passed. =="
    echo "Next: make -C os-image/efi build-efi-${arch}   (about 20 minutes cold; not run by this script)"
  else
    echo "== ${n} action(s) required before the ${arch} EFI build can succeed =="
    for scope in admin user; do
      case "${scope}" in
        admin) label="Run by an administrator (root):" ;;
        *) label="Run as the runner user:" ;;
      esac
      local printed=0
      for ((i = 0; i < n; i++)); do
        [[ "${act_scope[i]}" == "${scope}" ]] || continue
        if [[ ${printed} -eq 0 ]]; then
          echo "${label}"
          printed=1
        fi
        count=$((count + 1))
        printf '  %d. %s\n' "${count}" "${act_title[i]}"
        printf '       %s\n' "${act_cmd[i]}"
      done
    done
    echo
    echo "Then re-run this check."
    for ((i = 0; i < n; i++)); do
      if [[ "${act_scope[i]}" == admin ]]; then
        echo "Alternative for the administrator items: make -C os-image/efi setup-host (from an NVKE checkout, needs sudo)."
        break
      fi
    done
  fi
  if [[ ${#warnings[@]} -gt 0 ]]; then
    echo
    echo "== ${#warnings[@]} unverified item(s); these do not fail the check =="
    for ((i = 0; i < ${#warnings[@]}; i++)); do
      printf '  - %s\n' "${warnings[i]}"
    done
  fi
}

main() {
  run_checks
  report_actions
  [[ ${#act_scope[@]} -eq 0 ]]
}

report="${EFI_CHECK_REPORT:-}"
if [[ -n "${report}" ]]; then
  rc=0
  main >"${report}" 2>&1 || rc=$?
  cat "${report}"
  exit "${rc}"
fi
main
exit $?
