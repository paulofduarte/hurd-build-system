# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Arch-keyed qemu defaults + optional host-acceleration overlay.
#
# Defaults track upstream gnumach's test harness
# (src/gnumach/tests/user-qemu.mk lines ~208-225); keep in sync when
# upstream bumps the pinned CPU models or memory caps.

# arch_qemu_for_target <ARCH>
#   Sets: QEMU, QEMU_MACHINE, QEMU_CPU, QEMU_MEM, QEMU_CONSOLE
#
#   - CPU `-v1` suffix pins the qemu CPU-model version: future qemu
#     releases can change feature exposure (SSE generations, TSC
#     behaviour) and break gnumach in subtle ways. Upstream vets
#     `pentium3-v1` (i686) and `core2duo-v1` (x86_64) against every
#     gnumach test cycle.
#   - Memory caps are kernel-determined, not arbitrary:
#       i686/x86_64 -> 2047 MB (upper bound of the 32-bit signed
#                              "low" range gnumach's bootstrap pmap
#                              manages directly)
#       aarch64     ->  512 MB (aarch64 pmap_bootstrap maps a single
#                              1 GB L1 block in TTBR1; vm_page's
#                              allocator faults beyond that until
#                              AARCH64-PMAP-HEAP-DESIGN.md lands)
arch_qemu_for_target() {
  case "$1" in
    aarch64)
      export QEMU=qemu-system-aarch64
      QEMU_MACHINE=(-M virt)
      export QEMU_CPU=cortex-a72
      export QEMU_MEM=512
      export QEMU_CONSOLE=ttyAMA0
      ;;
    x86_64)
      export QEMU=qemu-system-x86_64
      QEMU_MACHINE=()
      export QEMU_CPU=core2duo-v1
      export QEMU_MEM=2047
      export QEMU_CONSOLE=com0
      ;;
    i686)
      export QEMU=qemu-system-i386
      QEMU_MACHINE=()
      export QEMU_CPU=pentium3-v1
      export QEMU_MEM=2047
      export QEMU_CONSOLE=com0
      ;;
    *) die "arch_qemu_for_target: unsupported ARCH=$1" ;;
  esac
}

# arch_apply_accel_if_requested
#   If $RUN_ACCEL=1 AND host arch matches $ARCH, append `-accel hvf`
#   (darwin) or `-accel kvm` (linux) to $QEMU_MACHINE and override
#   $QEMU_CPU to "host". Otherwise no-op (with a warning on
#   arch mismatch or unsupported platform).
#
#   IMPORTANT: This OVERRIDES the upstream-vetted pinned CPU
#   (pentium3-v1 / core2duo-v1 / cortex-a72), exposing the full host
#   CPU feature set to gnumach. gnumach has NOT been tested against
#   arbitrary modern CPU features (newer SSE/AVX, MTE on Apple
#   Silicon, etc.) - it may panic on unrecognized CPUID flags or hit
#   untested code paths. Use at your own risk.
#
#   Call AFTER arch_qemu_for_target and AFTER any scenario-specific
#   QEMU_MACHINE overrides (e.g., Guix's "-M q35") so the -accel flag
#   appends cleanly.
arch_apply_accel_if_requested() {
  [ "${RUN_ACCEL:-}" = "1" ] || return 0

  # Normalize host arch identifier across platforms:
  #   darwin reports `arm64`, linux reports `aarch64`
  #   linux reports `i386` / `i486` / `i586` / `i686`
  local host_arch
  case "$(uname -m)" in
    arm64 | aarch64) host_arch=aarch64 ;;
    x86_64 | amd64) host_arch=x86_64 ;;
    i?86) host_arch=i686 ;;
    *) host_arch="$(uname -m)" ;;
  esac

  # Compat matrix - which guests can each host accelerate?
  #   x86_64 host:  x86_64 + i686 (32-bit is a subset; same /dev/kvm)
  #   i686   host:  i686 only (32-bit host can't run 64-bit guests)
  #   aarch64 host: aarch64 only (different ISA family from x86)
  local accel_ok=0
  case "$host_arch:$ARCH" in
    x86_64:x86_64 | x86_64:i686 | i686:i686 | aarch64:aarch64) accel_ok=1 ;;
  esac
  if [ "$accel_ok" != "1" ]; then
    echo "RUN_ACCEL=1 ignored: host $host_arch cannot accelerate ARCH=$ARCH. Falling back to TCG." >&2
    return 0
  fi

  local accel
  case "$(uname -s)" in
    Darwin) accel=hvf ;;
    Linux) accel=kvm ;;
    *)
      echo "RUN_ACCEL=1 ignored: no known accelerator for $(uname -s). Falling back to TCG." >&2
      return 0
      ;;
  esac

  export QEMU_CPU=host
  # Append to the (possibly empty) machine-flag array.  Empty-array
  # expansion is safe under `set -u` on bash 4.4+; if
  # arch_qemu_for_target wasn't called first QEMU_MACHINE is unset, so
  # seed it to an empty array first to stay `set -u`-clean.
  [ "${QEMU_MACHINE+set}" = set ] || QEMU_MACHINE=()
  QEMU_MACHINE=("${QEMU_MACHINE[@]}" -accel "$accel")
  echo "RUN_ACCEL=1: using -accel $accel + -cpu host (upstream-pinned CPU model overridden - gnumach may panic on untested CPUID features)" >&2
}
