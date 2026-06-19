#!/bin/sh
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# overlay-kernel op - runs INSIDE the sidekick (dispatcher oneshot mode, so
# /shared is already 9p-mounted and busybox applets are installed; the
# target qcow2 is attached via -drive).  Host-staged into /shared/run.sh by
# flakes/run/lib/sidekick.sh.  Moved out of the VM image (was the Alpine
# init.sh overlay-kernel case) so the VM stays a generic dispatcher.
#
#   - mount the first writable ext partition of the attached disk;
#   - if /shared/kernel.bin is present, overlay it at the kernel path
#     auto-discovered from the disk's grub.cfg multiboot line (gzip-wrap
#     iff that path ends in .gz);
#   - regenerate a minimal /boot/grub/grub.cfg for clean -nographic boot,
#     pulling only the multiboot/module lines from the disk's first
#     non-recovery menuentry (flattening any `configfile` include).
set +e

# Block + ext drivers to reach the qcow2's ext partition (busybox modprobe
# resolves deps from the Alpine kernel's modules.dep: ext4->jbd2/mbcache/...).
for mod in virtio_pci virtio_blk sd_mod ext2 ext4; do
  modprobe "$mod" 2>/dev/null
done
sleep 1

part=
for p in /dev/vd[a-z][0-9]* /dev/sd[a-z][0-9]*; do
  [ -b "$p" ] || continue
  if mount "$p" /mnt 2>/dev/null; then
    part="$p"
    break
  fi
done
[ -n "$part" ] || {
  echo "FATAL: no mountable partition for kernel overlay" >&2
  sync
  exit 1
}

grub_cfg=/mnt/boot/grub/grub.cfg
if [ -f "$grub_cfg" ] && ! grep -q "^# sidekick-generated" "$grub_cfg"; then
  part_num=$(echo "$part" | sed 's|.*[a-z]||')

  # Inline one-level `configfile <path>` includes (Gentoo keeps its module
  # chain in a separate file); Debian inlines everything (no-op).
  flat_cfg=/tmp/grub-flat.cfg
  {
    while IFS= read -r line; do
      case "$line" in
        *configfile*)
          path=$(printf '%s\n' "$line" | sed -nE 's|^[[:space:]]*configfile[[:space:]]+(.+)[[:space:]]*$|\1|p')
          if [ -n "$path" ] && [ -f "/mnt$path" ]; then cat "/mnt$path"; else printf '%s\n' "$line"; fi
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <"$grub_cfg"
  } >"$flat_cfg"

  boot_lines=$(awk '
    /^menuentry / && !/recovery mode/ && !found { found=1; in_body=1; prev=""; next }
    in_body && /^}/ { if (prev != "") emit(prev); exit }
    in_body {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, " ", line); prev = prev line; next }
      if (prev != "") { prev = prev line; emit(prev); prev = "" } else { emit(line) }
    }
    function emit(line) {
      if (line ~ /^multiboot[[:space:]]/) {
        if (line !~ /console=com0/) line = line " console=com0"; print "  " line
      } else if (line ~ /^module[[:space:]]/) { print "  " line }
      else if (line ~ /^[A-Z][A-Z0-9_]*=[^[:space:]=]+$/) { print "  " line }
    }
  ' "$flat_cfg")

  kernel_path=$(printf '%s\n' "$boot_lines" | awk '/^[[:space:]]*multiboot[[:space:]]/{print $2; exit}')
  kernel_path=${kernel_path#/}

  if [ -f /shared/kernel.bin ] && [ -n "$kernel_path" ]; then
    [ -e "/mnt/$kernel_path" ] || {
      echo "FATAL: target kernel /mnt/$kernel_path missing" >&2
      sync
      umount /mnt
      exit 1
    }
    case "$kernel_path" in
      *.gz) gzip -c </shared/kernel.bin >"/mnt/$kernel_path" ;;
      *) cp /shared/kernel.bin "/mnt/$kernel_path" ;;
    esac
  fi

  {
    cat <<EOF
# sidekick-generated: minimal cfg for -nographic boot
serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial
set color_normal=light-gray/black
set color_highlight=white/black
set timeout=0

menuentry "hurd" {
  insmod part_msdos
  insmod ext2
  set root='hd0,msdos$part_num'
EOF
    printf '%s\n' "$boot_lines"
    cat <<'EOF'
  echo -e -n "\033[0m"
}
EOF
  } >"$grub_cfg"
fi

sync
umount /mnt 2>/dev/null
