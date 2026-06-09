#!/usr/bin/env bash
# SCENARIO=boot - bare kernel smoke test.  Universal across all
# supported ARCHs; for x86_64 we route through a tiny GRUB ISO
# (built by sidekick) because qemu's -kernel rejects 64-bit ELFs.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/arch-flags.sh"
. "$(dirname "$0")/lib/sidekick.sh"   # for x86_64 ISO build

scenario_check_target "boot" "aarch64 x86_64 i686"
arch_qemu_for_target "$ARCH"        # sets $QEMU, $QEMU_MACHINE, $QEMU_CPU, $QEMU_MEM, $QEMU_CONSOLE
arch_apply_accel_if_requested         # may append -accel + override QEMU_CPU when RUN_ACCEL=1

extra_qemu_args=("$@")                # capture RUN_ARGS pass-through

if [ "$ARCH" = "x86_64" ]; then
  # 64-bit gnumach + qemu multiboot1 don't mix (see D18); wrap it
  # in a minimal GRUB ISO and boot via -cdrom instead of -kernel.
  cache="$WORK/test-images/boot/x86_64"
  staging="$cache/iso-staging"
  iso="$cache/boot.iso"
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -L "$GNUMACH_KERNEL" "$staging/$(basename "$GNUMACH_KERNEL")"

  grub_cfg=$(
    printf 'set timeout=0\n'
    printf 'menuentry "boot" {\n'
    printf '  multiboot /%s console=%s\n' "$(basename "$GNUMACH_KERNEL")" "$QEMU_CONSOLE"
    printf '  boot\n'
    printf '}\n'
  )
  # Cache key = the kernel's nix-store path (content-addressed when
  # via `nix run`, so it changes iff the kernel content changes;
  # when via `make run` it's a $WORK path that updates on rebuild).
  # sidekick_make_iso hashes this + grub.cfg to decide whether the
  # ISO can be reused.
  sidekick_make_iso "$iso" "$staging" "$grub_cfg" "$GNUMACH_KERNEL"

  # -no-reboot: gnumach's `boot` test prints "Hello" then exits.  Without
  # this, qemu cycles back to GRUB and the user sees a phantom second
  # boot instead of the "exit at PASS" they expected.
  print_qemu_hint
  exec "$QEMU" -nographic $QEMU_MACHINE -m "$QEMU_MEM" -cpu "$QEMU_CPU" \
    -boot order=d \
    -cdrom "$iso" \
    -no-reboot \
    "${extra_qemu_args[@]}"
fi

# i686 / aarch64: direct -kernel works fine.
# -no-reboot per the rationale above.
print_qemu_hint
exec "$QEMU" -nographic $QEMU_MACHINE -m "$QEMU_MEM" -cpu "$QEMU_CPU" \
  -kernel "$GNUMACH_KERNEL" \
  -append "console=$QEMU_CONSOLE" \
  -no-reboot \
  "${extra_qemu_args[@]}"
