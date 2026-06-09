#!/bin/sh
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# mkiso op - runs INSIDE the sidekick (dispatcher oneshot mode; /shared
# already mounted, busybox installed).  Host-staged into /shared/run.sh by
# flakes/run/lib/sidekick.sh, with /shared/iso-staging/ (kernel + multiboot
# modules) and /shared/iso-grub.cfg prepared host-side.  Wraps them in a
# GRUB-bootable ISO at /shared/out.iso via grub-mkrescue (Debian: it execs
# xorriso + mtools + grub-mkimage, all present in the VM).
set +e
cd /shared
[ -f iso-grub.cfg ] || { echo "FATAL: /shared/iso-grub.cfg missing" >&2; exit 1; }
[ -d iso-staging ]  || { echo "FATAL: /shared/iso-staging/ missing" >&2; exit 1; }

rm -rf iso-root; mkdir -p iso-root/boot/grub
cp iso-grub.cfg iso-root/boot/grub/grub.cfg
cp -a iso-staging/. iso-root/

grub-mkrescue -o out.iso iso-root 2>&1 \
  || { echo "FATAL: grub-mkrescue failed" >&2; exit 1; }
sync
