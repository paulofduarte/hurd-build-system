#!/usr/bin/env bash
# SCENARIO=hurd-guix — Guix childhurd; hybrid-extract inject; needs -M q35.
#
# TODO: migrate to the kernel-overlay approach used by hurd-debian /
# hurd-gentoo.  Blocked on the Guix kernel path containing a store
# hash (/gnu/store/<hash>-gnumach-<ver>/boot/gnumach), which the
# sidekick overlay-kernel op currently doesn't glob-resolve.  Two
# possible fixes: (a) extend sidekick to accept glob patterns in
# target_path, (b) discover the path host-side via an extra sidekick
# extract pass that returns the resolved kernel path.
# URL uses Cuirass's /search/latest/image endpoint (auto-resolves to latest
# successful build with a fetchable artefact; never goes stale).
#
# TARGET=x86_64 usually returns upstream 500 because Guix CI aggressively
# garbage-collects 64-bit qcow2 artefacts; the GC explanation is surfaced
# inline via $guix_x86_64_hint when that path fails. TARGET=i686 is
# reliably available.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
. "$(dirname "$0")/lib/hurd-common.sh"
. "$(dirname "$0")/lib/sidekick.sh"

scenario_check_target "hurd-guix" "x86_64 i686"
arch_qemu_for_target "$TARGET"
QEMU_MACHINE="-M q35"            # Guix qcow2 won't boot on i440fx — override default
arch_apply_accel_if_requested    # appends -accel to QEMU_MACHINE if RUN_ACCEL=1 + arch match

extra_qemu_args=("$@")           # capture RUN_ARGS pass-through

case "$TARGET" in
  x86_64) url="$HURD_GUIX_X86_64_URL"; qcow2_name="hurd64-barebones.qcow2"
          extra_cmdline=" noide" ;;
  i686)   url="$HURD_GUIX_I686_URL";   qcow2_name="hurd-barebones.qcow2"
          extra_cmdline="" ;;
esac

# Pass the GC-explanation hint only for x86_64 (i686 rarely fails).
guix_x86_64_hint="Guix CI x86_64 hurd64-barebones.qcow2 artefacts are
aggressively GC'd upstream.  This is upstream's fail-fast behaviour,
not a harness bug.

Options:
  - Re-try later (Guix CI rebuilds 64-bit Hurd periodically)
  - Use the 32-bit variant instead:
        make run TARGET=i686 SCENARIO=hurd-guix"
[ "$TARGET" = x86_64 ] && hint="$guix_x86_64_hint" || hint=""

cache="$(hurd_cache_dir guix "$TARGET")"
qcow2="$cache/$qcow2_name"
hurd_fetch_via_resolve "$url" "$qcow2" "$cache/last-target" "$hint"

overlay="$cache/overlay.qcow2"
hurd_make_overlay "$qcow2" "$overlay" qcow2

# Vanilla path: skip extraction (we won't be using our kernel).
# QEMU_MACHINE="-M q35" (+ any -accel) is read here too — single source of truth.
hurd_maybe_vanilla_exec "$QEMU" -nographic -m "$QEMU_MEM" $QEMU_MACHINE -cpu "$QEMU_CPU" \
  -drive file="$overlay",format=qcow2 \
  "${extra_qemu_args[@]}"

# Default: extract modules then boot OUR kernel.  Same dynamic-exec
# pattern as Gentoo: ld.so.1 is the multiboot module; it loads
# /hurd/exec from the mounted root after ext2fs comes up.
sidekick_extract "$qcow2" "$cache/extracted" \
  "hurd/ext2fs.static lib/ld.so.1"

modules="$cache/extracted/ext2fs.static --multiboot-command-line=\${kernel-command-line} --host-priv-port=\${host-port} --device-master-port=\${device-port} --exec-server-task=\${exec-task} -T typed \${root} \$(task-create) \$(task-resume),$cache/extracted/ld.so.1 exec /hurd/exec \$(exec-task=task-create)"

cmdline="root=device:hd0s1 console=$QEMU_CONSOLE$extra_cmdline"

hurd_exec_with_our_kernel "$overlay" "$modules" "$cmdline" "${extra_qemu_args[@]}"
