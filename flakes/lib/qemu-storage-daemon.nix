# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Minimal qemu-storage-daemon for the sidekick guest's qcow2 read path.
#
# The sidekick guest needs to read one file (the distro's /boot/grub/grub.cfg)
# out of a qcow2 distro image to build the option-1 boot ISO. `debugfs` reads a
# RAW ext partition directly (`?offset=`), but not the qcow2 container; so we
# expose the qcow2 as a raw FUSE file with `qemu-storage-daemon --export
# type=fuse`, then `debugfs` reads that.
#
# This is the TOOLS-ONLY qemu build (qemu-utils, i.e. `--disable-system`: NO
# qemu-system-* emulators — the guest never boots a VM, the host does) with FUSE
# export enabled. ~150 MB vs full qemu's ~2 GB. Built once and pushed to our
# cache (the fuse-enabled variant is not on the upstream cache).
pkgs:

pkgs.qemu-utils.override { fuseSupport = true; }
