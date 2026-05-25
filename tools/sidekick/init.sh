#!/bin/sh
# /init for the sidekick helper VM.  PID 1 inside qemu.
#
# Operation is selected via the kernel cmdline:
#   SIDEKICK_OP=extract  EXTRACT_FILES="<paths>"
#       Mount /dev/vdb's first ext{2,3,4} partition read-only and copy
#       the requested files (paths relative to that mount; globs OK)
#       to the host-shared 9p mount.  Output filenames are
#       basename-only — /shared/<basename>.
#
#   SIDEKICK_OP=mkiso
#       Read /shared/iso-input.cfg (host-prepared) for the kernel +
#       multiboot-module + GRUB-config layout, run grub-mkrescue, and
#       write the result to /shared/out.iso.  Lets the host bypass
#       qemu's multiboot1 32-bit-ELF restriction for x86_64 gnumach.

set +e
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Install busybox applet symlinks (mount, mkdir, cat, sync, poweroff,
# blkid, …).  Alpine normally does this in its post-install hook; we
# extract tarballs only, so we run --install ourselves at boot.
# Must be the FIRST real command — everything below needs the symlinks.
/bin/busybox --install -s /bin

# Wire up basic mounts.
mount -t proc     proc /proc
mount -t sysfs    sys  /sys
mount -t devtmpfs dev  /dev 2>/dev/null

# Some Alpine binaries expect /tmp.
mkdir -p /tmp /mnt /shared

# Host share — always present on every sidekick invocation.
mount -t 9p -o trans=virtio,version=9p2000.L shared /shared \
  || { echo "FATAL: 9p mount of shared/ failed" >&2; sync; poweroff -f; }

# Parse kernel cmdline into shell vars.  ONLY SIDEKICK_OP is read
# here — file lists go via the 9p share (/shared/.sidekick-extract-files)
# because Linux truncates the cmdline at 256 bytes, which the amd64
# 4-module chain already overflows.
for arg in $(cat /proc/cmdline); do
  case "$arg" in
    SIDEKICK_OP=*) eval "$arg" ;;
  esac
done

SIDEKICK_OP=${SIDEKICK_OP:-}
case "$SIDEKICK_OP" in
  extract)
    # Alpine's linux-virt kernel ships virtio bus + block + ext{2,3,4}
    # as MODULES (not built-in).  PCI scan finds the virtio-block
    # device, but without virtio_blk loaded nothing claims it — so
    # /dev/vdb never appears and the partition scan finds nothing.
    # Modprobe everything we need up front; failures are non-fatal
    # because module names occasionally shift across kernel versions
    # (e.g., virtio_pci vs virtio-pci), and the subsequent mount
    # calls are the real correctness check.
    for mod in virtio virtio_pci virtio_blk \
               sd_mod scsi_mod \
               ext2 ext4; do
      modprobe "$mod" 2>/dev/null
    done

    # Give udev/devtmpfs a moment to populate /dev/vdb* after the
    # virtio_blk driver binds — without this we sometimes race and
    # find no partitions even though they're about to appear.
    sleep 1

    # Find + mount the first mountable partition.  Just try `mount -o ro`
    # on each numbered virtio partition — kernel auto-detects ext2/3/4
    # and rejects swap (gives "Invalid argument").  This is more robust
    # than blkid pre-checks: busybox's `blkid -t TYPE=ext2 /dev/vda`
    # (whole-disk-with-MBR) misbehaves and reports a false positive
    # against the ext2 superblock nested inside the partition table,
    # then the mount of the whole disk fails with "Invalid argument".
    # Skipping the whole disk and just trying partitions avoids both
    # problems.  All our supported distro images (Debian, Gentoo, Guix)
    # use partitioned disks; an unpartitioned ext2 (raw FS at /dev/vda)
    # would need a separate code path.
    part=
    for p in /dev/vd[a-z][0-9]*; do
      [ -b "$p" ] || continue
      if mount -o ro "$p" /mnt 2>/dev/null; then
        part="$p"
        break
      fi
    done
    if [ -z "$part" ]; then
      echo "FATAL: no mountable partition found on /dev/vd*[0-9]" >&2
      echo "  available block devices:" >&2
      ls -la /dev/vd* /dev/sd* 2>/dev/null | sed 's/^/    /' >&2
      echo "  loaded modules:" >&2
      lsmod 2>/dev/null | head -20 | sed 's/^/    /' >&2
      sync; poweroff -f
    fi

    # Read the file list the host prepared on the 9p share.
    [ -f /shared/.sidekick-extract-files ] \
      || { echo "FATAL: /shared/.sidekick-extract-files missing — host orchestrator didn't write it" >&2; sync; poweroff -f; }
    extract_files=$(cat /shared/.sidekick-extract-files)

    # Copy each pattern to /shared/<basename>.  Globs are expanded by
    # the shell after `cd /mnt`; empty expansions skipped silently.
    # cp -L dereferences symlinks so we get the target's bytes
    # (matters for things like /lib/ld.so.1 → ld-x86-64.so.1).
    ( cd /mnt
      for pattern in $extract_files; do
        for f in $pattern; do
          [ -e "$f" ] || continue
          cp -L "$f" "/shared/$(basename "$f")"
        done
      done
    )
    sync
    umount /mnt
    ;;

  overlay-kernel)
    # Replace a kernel binary inside an attached qcow2 overlay with
    # /shared/kernel.bin.  Host writes the target path into
    # /shared/.sidekick-overlay-kernel-target.  Distros that ship a
    # gzipped kernel get the replacement gzipped to match.
    for mod in virtio virtio_pci virtio_blk \
               sd_mod scsi_mod \
               ext2 ext4; do
      modprobe "$mod" 2>/dev/null
    done
    sleep 1

    # Kernel overlay is optional — if /shared/kernel.bin is absent
    # (vanilla mode), we skip the kernel copy but still generate the
    # clean grub.cfg below so the distro's bundled kernel boots on
    # serial.  Both kernel.bin and target must be present together.
    do_kernel_overlay=0
    if [ -f /shared/kernel.bin ] && [ -f /shared/.sidekick-overlay-kernel-target ]; then
      do_kernel_overlay=1
      target_path=$(cat /shared/.sidekick-overlay-kernel-target)
      target_path=${target_path#/}    # strip any leading /
    fi

    # Find + mount the first writable ext partition (skip swap).
    part=
    for p in /dev/vd[a-z][0-9]*; do
      [ -b "$p" ] || continue
      if mount "$p" /mnt 2>/dev/null; then
        part="$p"
        break
      fi
    done
    [ -n "$part" ] \
      || { echo "FATAL: no mountable partition for kernel overlay" >&2; sync; poweroff -f; }

    if [ "$do_kernel_overlay" = "1" ]; then
      # Target kernel must already exist — that's what the distro's
      # GRUB config references.  Writing a new file at a wrong path
      # wouldn't help (GRUB would still load from the original path).
      [ -e "/mnt/$target_path" ] \
        || { echo "FATAL: target kernel /mnt/$target_path missing — wrong path?" >&2;
             sync; umount /mnt; poweroff -f; }
      case "$target_path" in
        *.gz) gzip -c < /shared/kernel.bin > "/mnt/$target_path" ;;
        *)    cp /shared/kernel.bin "/mnt/$target_path" ;;
      esac
    fi

    # Generate a fresh, minimal /boot/grub/grub.cfg from scratch.
    # Pull ONLY the `multiboot` + `module` lines from the disk's
    # existing first non-recovery menuentry — that's the distro's
    # verified boot recipe.  Hardcode everything else (insmod, set
    # root, serial, timeout, terminal) from our knowledge of the
    # mount.  No load_video / gfxterm / themes / recordfail leak
    # through, so nothing emits ANSI colour or VGA-init code.
    #
    # Critical: Debian's grub.cfg splits long `module` lines across
    # multiple lines with backslash continuations.  The awk joins
    # them before emitting.  Verified against the real disk's cfg
    # via orb (2026-05-25).
    #
    # Idempotent: gated on the `# sidekick-generated` marker.
    grub_cfg=/mnt/boot/grub/grub.cfg
    if [ -f "$grub_cfg" ] && ! grep -q "^# sidekick-generated" "$grub_cfg"; then
      # Partition index from the device we mounted (e.g. /dev/vda2 → 2)
      # — GRUB's BIOS naming maps to (hd0,msdos<N>) for an IDE disk.
      part_num=$(echo "$part" | sed 's|.*[a-z]||')

      boot_lines=$(awk '
        /^menuentry / && !/recovery mode/ && !found { found=1; in_body=1; prev=""; next }
        in_body && /^}/ { if (prev != "") emit(prev); exit }
        in_body {
          line = $0
          sub(/^[[:space:]]+/, "", line)
          if (line ~ /\\$/) {
            sub(/[[:space:]]*\\$/, " ", line)
            prev = prev line
            next
          }
          if (prev != "") { prev = prev line; emit(prev); prev = "" }
          else            { emit(line) }
        }
        function emit(line) {
          if (line ~ /^multiboot[[:space:]]/) {
            if (line !~ /console=com0/) line = line " console=com0"
            print "  " line
          } else if (line ~ /^module[[:space:]]/) {
            print "  " line
          }
        }
      ' "$grub_cfg")

      # Three sections so the source stays readably-indented:
      #   - header (heredoc with $part_num substitution)
      #   - boot_lines (printf; lines already carry "  " prefix from awk)
      #   - footer (quoted heredoc so \033 reaches GRUB literally)
      {
        cat <<EOF
# sidekick-generated: minimal cfg for -nographic boot
serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial
# Match highlight to normal so GRUB's "Welcome to GRUB!" banner
# doesn't ANSI-invert to black-on-white (white background bleeds
# into the host terminal and persists).
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
}
EOF
      } > "$grub_cfg"
    fi

    sync
    umount /mnt
    ;;

  mkiso)
    # Host prepares /shared/iso-staging/ with the gnumach binary and
    # the modules to bake into the ISO, plus /shared/iso-grub.cfg
    # which becomes /boot/grub/grub.cfg in the ISO image.
    cd /shared
    [ -f iso-grub.cfg ] || { echo "FATAL: /shared/iso-grub.cfg missing" >&2; sync; poweroff -f; }
    [ -d iso-staging ] || { echo "FATAL: /shared/iso-staging/ missing" >&2; sync; poweroff -f; }

    mkdir -p iso-root/boot/grub
    cp iso-grub.cfg iso-root/boot/grub/grub.cfg
    # iso-staging mirrors what the GRUB cfg references — gnumach +
    # modules.  Caller arranges the layout; we just merge it in.
    cp -a iso-staging/. iso-root/

    grub-mkrescue -o out.iso iso-root 2>&1 \
      || { echo "FATAL: grub-mkrescue failed" >&2; sync; poweroff -f; }

    sync
    ;;

  *)
    echo "FATAL: unknown SIDEKICK_OP=$SIDEKICK_OP" >&2
    echo "       supported: extract, mkiso" >&2
    ;;
esac

# Clean shutdown — the host waits for qemu to exit and then reads
# the output files from its side of the 9p share.
sync
poweroff -f
