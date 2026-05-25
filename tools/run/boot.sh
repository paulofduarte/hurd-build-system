#!/usr/bin/env bash
# SCENARIO=boot — bare kernel via qemu -kernel. Universal smoke test.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"

scenario_check_target "boot" "aarch64 x86_64 i686"
arch_qemu_for_target "$TARGET"        # sets $QEMU, $QEMU_MACHINE, $QEMU_CPU, $QEMU_MEM, $QEMU_CONSOLE
arch_apply_accel_if_requested         # may append -accel + override QEMU_CPU when RUN_ACCEL=1

extra_qemu_args=("$@")                # capture RUN_ARGS pass-through

print_qemu_hint                       # one-line hint + set terminal title
exec "$QEMU" -nographic $QEMU_MACHINE -m "$QEMU_MEM" -cpu "$QEMU_CPU" \
  -kernel "$GNUMACH_BOOT_IMAGE" \
  -append "console=$QEMU_CONSOLE" \
  "${extra_qemu_args[@]}"
