#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# SCENARIO=hurd-self - boot the SELF-BUILT system: the dist runtime tree
# assembled into a fresh ext2 image, no distro bits at all.
#
# Phase 3 (controlled test): i686 on gnumach's in-kernel hd0 driver with the
# verified 2-module dynamic-exec chain (ext2fs.static + ld.so.1 running
# /hurd/exec) - the fewest moving parts that can boot, so a failure here is
# the userland/boot plumbing, never the rump storage stack.  x86_64 arrives
# with the 5-module rumpdisk chain (phase 5), which also retires this hd0
# path (the phase-5 kernel drops all in-kernel drivers at compile time).
#
# First-boot bootstrap facts this scenario RELIES on (no pre-seeded passive
# translators - mke2fs cannot write Hurd translator records):
#   - console-run falls back to the Mach console when /dev/console has no
#     translator, setting FALLBACK_CONSOLE;
#   - runsystem then goes SINGLE-USER directly (a bash prompt on the serial
#     console) - which is exactly the controlled-test PASS surface;
#   - runsystem self-heals /servers/socket/1 (settrans -c ... /hurd/pflocal),
#     which needs the image's creator-OS to be `hurd` (mke2fs -o hurd
#     enables the inode translator field).
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/arch-flags.sh
. "$(dirname "$0")/lib/arch-flags.sh"

scenario_check_target "hurd-self" "i686"
arch_qemu_for_target "$ARCH"  # sets $QEMU, $QEMU_MACHINE, $QEMU_CPU, $QEMU_MEM, $QEMU_CONSOLE
arch_apply_accel_if_requested # may append -accel + override QEMU_CPU when RUN_ACCEL=1

[ "${RUN_VANILLA:-}" != 1 ] || die "RUN_VANILLA makes no sense for hurd-self (there is no distro kernel)"

extra_qemu_args=("$@") # capture RUN_ARGS pass-through

: "${WORK:?WORK required (set by the Makefile / nix-run app)}"
: "${DIST:?DIST required - run via 'make run' (and 'make dist ARCH=i686' first)}"
runtime="$DIST/runtime"
[ -d "$runtime" ] || die "no dist runtime at $runtime - run 'make dist ARCH=$ARCH' first"
[ -x "$runtime/usr/bin/bash" ] || die "dist runtime has no bash (dist predates dist-base?) - re-run 'make dist ARCH=$ARCH'"
[ -f "$runtime/hurd/ext2fs.static" ] || die "dist runtime has no /hurd/ext2fs.static - re-run 'make dist ARCH=$ARCH'"

cache="$WORK/test-images/${RUN_VARIANT:-}hurd-self/$ARCH"
rootfs="$cache/rootfs"
img="$cache/root.img"

# Assemble the rootfs: the split runtime tree verbatim (it already carries
# the usr-merge compat symlinks bin/lib/sbin/libexec -> usr/*) + the mutable
# dirs a boot needs.  Always reassembled - runs are interactive and the copy
# is seconds; correctness beats caching a stale tree.
echo "  ASSEMBLE  $rootfs (from $runtime)"
rm -rf "$rootfs"
mkdir -p "$cache"
cp -a "$runtime/." "$rootfs/"
mkdir -p "$rootfs/dev" "$rootfs/servers/socket" "$rootfs/tmp" \
  "$rootfs/root" "$rootfs/mnt" "$rootfs/var/run" "$rootfs/var/log"
chmod 1777 "$rootfs/tmp"
# The standard /servers node FILES.  /servers/exec is needed at exec
# bootstrap itself: ext2fs's diskfs_execboot_fsys_startup dir_lookup()s it
# to hand the exec server its node and assert_perror's on ENOENT
# (libdiskfs/boot-start.c) - cost boot attempt 2.  The others are the
# conventional translator seats (Debian ships the same set as empty files);
# translators land on them at/after first boot, the nodes just have to
# exist.
touch "$rootfs/servers/exec" "$rootfs/servers/startup" \
  "$rootfs/servers/proc" "$rootfs/servers/default-pager" \
  "$rootfs/servers/password" "$rootfs/servers/crash" \
  "$rootfs/servers/crash-dump-core" "$rootfs/servers/crash-kill" \
  "$rootfs/servers/crash-suspend"
# tty1-6 off: their /dev nodes are translator-backed and can only be created
# ON Hurd (MAKEDEV at first boot - the parked passive-translator bootstrap,
# #17); until then runttys would respawn-flood getty against the missing
# nodes.  Image-copy edit, not a package change - hurd owns /etc/ttys.
sed -i.orig -E 's|^(tty[1-6][[:space:]].*)\bon\b|\1off|' "$rootfs/etc/ttys"
rm -f "$rootfs/etc/ttys.orig"

# ext2 image: creator-OS `hurd` (see header), plain ext2, sized to the tree
# + slack for first-boot writes (translator records, logs, root's shell
# history).  -F: it's a regular file; -q: the mke2fs banner isn't news.
echo "  MKE2FS    $img"
tree_kb=$(du -sk "$rootfs" | cut -f1)
size_kb=$(((tree_kb * 12 / 10) + 65536))
rm -f "$img"
mke2fs -q -F -t ext2 -o hurd -b 4096 -d "$rootfs" "$img" "${size_kb}k"

# The 2-module dynamic-exec chain (BOOT-CHAINS.md): gnumach itself
# substitutes the ${...}/$(...) boot-script variables - they must reach it
# literally.  Module files are HOST paths (qemu multiboot); the root device
# is the whole disk (no partition table) -> device:hd0.
#
# ARGV GOTCHA (cost the first boot): rtld invoked as a command parses
# `ld.so PROGRAM [ARGS...]` - argv[0] skipped, argv[1] = the program.  GRUB
# passes only the ARGUMENTS after the file as the module cmdline, so distro
# cfgs write `module /lib/ld.so.1 exec /hurd/exec` where "exec" is a mere
# argv0 LABEL.  qemu's -initrd instead bakes the FILE PATH in as argv0 -
# copying the distro shape verbatim made rtld try to load a file literally
# named "exec" (silent stall right after ext2fs printed `exec`).  So: no
# label here - the path itself is argv0, /hurd/exec is argv1.
m1="$runtime/hurd/ext2fs.static"
m2="$runtime/usr/lib/ld.so.1"
[ -f "$m2" ] || die "dist runtime has no usr/lib/ld.so.1 (glibc dist missing?)"

# -s: single-user - runsystem drops straight into a root shell on the boot
# console (fully interactive over serial).  The multi-user path already works
# up to runttys, but getty needs the translator-backed /dev/tty* nodes that
# only first-boot MAKEDEV can create (parked with #17's passive-translator
# bootstrap); single-user IS the phase-3 controlled-test surface.
print_qemu_hint
exec "$QEMU" -nographic "${QEMU_MACHINE[@]}" -m "$QEMU_MEM" -cpu "$QEMU_CPU" \
  -kernel "$GNUMACH_KERNEL" \
  -initrd "$m1 --multiboot-command-line=\${kernel-command-line} --host-priv-port=\${host-port} --device-master-port=\${device-port} --exec-server-task=\${exec-task} -T typed \${root} \$(task-create) \$(task-resume),$m2 /hurd/exec \$(exec-task=task-create)" \
  -append "root=device:hd0 console=$QEMU_CONSOLE -s" \
  -drive file="$img",format=raw \
  -no-reboot \
  "${extra_qemu_args[@]}"
