# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# The /etc skeleton for the self-built bootable system (phase-2 base
# userland; Debian's "base-files" analogue).  hurd's own install already
# ships etc/{ttys,login,motd,rpc} and dist-tzdata drops etc/localtime; this
# adds what reaching a shell needs on top:
#
#   passwd/group  - a passwordless root (dev bootstrap system; no shadow),
#                   shell /bin/bash (the usr-merge /bin -> /usr/bin compat
#                   symlink resolves it to dist-base's bash).
#   shells        - valid login shells (bash/sh, both /bin and /usr/bin).
#   profile       - system-wide PATH for login shells.
#   nsswitch.conf - glibc NSS: files everywhere (hosts: files dns).
#   hostname      - "hurd".
#   fstab         - header only; the boot ext2fs is a kernel-cmdline module,
#                   per-image entries are the image-assembly scenario's job.
#
# Arch-independent (pure text): ONE derivation serves every target, staged
# by dist-base alongside the per-arch bash/coreutils.  The files live next
# to this file under etc/ (REUSE.toml annotates them - passwd(5) has no
# comment syntax for SPDX headers).

{
  nixpkgs,
  system,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
in
pkgs.runCommandLocal "base-files-1"
  {
    meta = with lib; {
      description = "/etc skeleton for the self-built Hurd system";
      platforms = platforms.all;
      license = licenses.gpl3Plus;
    };
  }
  ''
    mkdir -p $out/etc
    cp ${./etc}/* $out/etc/
    chmod 644 $out/etc/*
  ''
