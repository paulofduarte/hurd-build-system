#!/usr/bin/env bash
# SCENARIO=hurd-gentoo — Gentoo Hurd userland; hybrid-extract inject.
# Gentoo bundles its multiboot modules inside the qcow2, so the helper VM
# extracts them once per (distro, TARGET) to a host cache.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
. "$(dirname "$0")/lib/hurd-common.sh"
. "$(dirname "$0")/lib/sidekick.sh"

scenario_check_target "hurd-gentoo" "x86_64 i686"
arch_qemu_for_target "$TARGET"
arch_apply_accel_if_requested

extra_qemu_args=("$@")   # capture RUN_ARGS pass-through

case "$TARGET" in
  x86_64) url="$HURD_GENTOO_X86_64_URL" ;;
  i686)   url="$HURD_GENTOO_I686_URL" ;;
esac

cache="$(hurd_cache_dir gentoo "$TARGET")"
qcow2="$cache/$(basename "$url")"
hurd_fetch_once_verified "$url" "$qcow2" "$url.sha512"

overlay="$cache/overlay.qcow2"
hurd_make_overlay "$qcow2" "$overlay" qcow2

# Vanilla path: skip extraction (we won't be using our kernel).
# $QEMU_MACHINE expanded unquoted so RUN_ACCEL=1's "-accel hvf/kvm" propagates;
# empty in the no-accel default case (Gentoo has no per-scenario machine override).
hurd_maybe_vanilla_exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2 \
  "${extra_qemu_args[@]}"

# Default: extract modules then boot OUR kernel.  Gentoo uses the
# dynamic-exec boot model: ld.so.1 is loaded as a multiboot module
# and its per-module cmdline tells it to load /hurd/exec from the
# mounted root after ext2fs.static comes up.  No standalone `exec`
# multiboot module needed.
sidekick_extract "$qcow2" "$cache/extracted" \
  "hurd/ext2fs.static lib/ld.so.1"

modules="$cache/extracted/ext2fs.static --multiboot-command-line=\${kernel-command-line} --host-priv-port=\${host-port} --device-master-port=\${device-port} --exec-server-task=\${exec-task} -T typed \${root} \$(task-create) \$(task-resume),$cache/extracted/ld.so.1 exec /hurd/exec \$(exec-task=task-create)"

cmdline="root=device:hd0s1 console=$QEMU_CONSOLE"

hurd_exec_with_our_kernel "$overlay" "$modules" "$cmdline" "${extra_qemu_args[@]}"
