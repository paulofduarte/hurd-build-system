# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Headless qemu - the `minimal` build, which drops the GUI (gtk/sdl/vnc/spice) and
# audio (alsa/pulse/pipewire/jack) backends.  `make run` / `nix run .#<arch>` always
# boot `-nographic` on a serial console (see flakes/run), so those backends are pure
# download + closure bloat - very visible on a fresh Linux machine.  `minimal` keeps
# every system emulator (qemu-system-{x86_64,i386,aarch64}) plus virtio, 9p (the
# sidekick's /shared mount) and disk, so boot and the sidekick are unaffected.
# One definition, shared by the dev shell and the `nix run` apps.
pkgs: pkgs.qemu.override { minimal = true; }
