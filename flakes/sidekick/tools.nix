# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# The sidekick's two ATOMIC x86-boot-media tools, shared by BOTH the guest
# (darwin, run via `sidekick-run`) and the Linux dev shell (native). These are
# single-purpose tools, NOT orchestration — the ISO-building logic lives on the
# host (flakes/run/lib/). grub's tools are cross-capable, so we build x86 BIOS
# ISOs even on aarch64 by feeding grub-mkrescue the i386-pc modules from x86_64
# grub.
#
#   sidekick-mkrescue  -> grub-mkrescue forced to the i386-pc (x86 BIOS) target
#   sidekick-imgcp     -> copy one file out of a (partitioned) disk image
#                         (read-only FUSE view + debugfs); the image is untouched
#
# `deps` are the runtime tools the scripts resolve from PATH — added to the guest
# systemPackages / the dev shell so the scripts work in both. fusermount3 is NOT
# bundled: it must be the system's setuid wrapper, so it comes from ambient PATH.
{
  pkgs,
  i386Grub, # x86_64 grub2 (its lib/grub/i386-pc); native grub2 on x86_64
}:
let
  storageDaemon = import ../lib/qemu-storage-daemon.nix pkgs;
in
rec {
  deps = with pkgs; [
    e2fsprogs # debugfs (read the distro grub.cfg + fs UUID off the raw ext part)
    storageDaemon # qemu-storage-daemon (qcow2/raw -> read-only FUSE raw view)
    util-linux # sfdisk (partition offsets)
    grub2 # grub-mkrescue (the tool)
    xorriso # grub-mkrescue ISO backend
    mtools # grub-mkrescue EFI helper
    gawk
    gnused
    coreutils
  ];

  sidekick-mkrescue = pkgs.writeShellScriptBin "sidekick-mkrescue" ''
    exec ${pkgs.grub2}/bin/grub-mkrescue -d ${i386Grub}/lib/grub/i386-pc "$@"
  '';

  sidekick-imgcp = pkgs.writeShellScriptBin "sidekick-imgcp" (builtins.readFile ./sidekick-imgcp.sh);
}
