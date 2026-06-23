# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Headless qemu - the `minimal` build, which drops the GUI (gtk/sdl/vnc/spice) and
# audio (alsa/pulse/pipewire/jack) backends.  `make run` / `nix run .#<arch>` always
# boot `-nographic` on a serial console (see flakes/run), so those backends are pure
# download + closure bloat - very visible on a fresh Linux machine.
#
# `minimal` does NOT trim the target list, though: it still builds ALL ~29
# qemu-system-* emulators (alpha, avr, m68k, mips, sparc, s390x, xtensa, ...) -
# ~435 MiB of binaries we never run.  Pin hostCpuTargets to the four we use, cutting
# the closure ~7x:
#   i386-softmmu / x86_64-softmmu  - the x86 Hurd targets (i686 + x86_64, incl. xen),
#                                    via flakes/run/lib/arch-flags.sh.
#   arm-softmmu / aarch64-softmmu  - 32- and 64-bit ARM: the sidekick VM and the
#                                    upcoming arm/aarch64 gnumach/hurd port.
# virtio, 9p (the sidekick's /shared mount) and disk are unconditional, so boot and
# the sidekick are unaffected.
#
# Native acceleration is untouched: KVM/HVF is a per-binary runtime `-accel` backend
# (qemu auto-enables it for the host; `minimal` doesn't disable it), not a target -
# an x86 guest gets KVM on x86_64-linux / HVF on x86_64-darwin, an aarch64 guest gets
# KVM/HVF on an aarch64 host, and any cross-arch guest falls back to TCG.
# One definition, shared by the dev shell and the `nix run` apps.
pkgs:
(pkgs.qemu.override {
  minimal = true;
  hostCpuTargets = [
    "i386-softmmu"
    "x86_64-softmmu"
    "arm-softmmu"
    "aarch64-softmmu"
  ];
}).overrideAttrs
  (_: {
    # qemu sets separateDebugInfo=true, which on Linux emits a ~177 MiB `debug`
    # output of detached symbols.  We never gdb qemu, and the dev-shell
    # inputDerivation drags that output into the pushed closure - so drop it.
    # Not an .override arg, hence overrideAttrs; stdenv still strips, so `out` is
    # unchanged.  (No-op on Darwin, which already dontStrips.)
    separateDebugInfo = false;
  })
