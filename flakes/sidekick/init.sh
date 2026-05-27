#!/bin/sh
# /init for the sidekick helper VM.  PID 1 inside qemu.
#
# Operation is selected via the kernel cmdline:
#   SIDEKICK_OP=overlay-kernel
#       Mount the attached qcow2 (read-write), optionally overlay
#       /shared/kernel.bin onto the kernel path discovered from the
#       disk's grub.cfg multiboot line, and regenerate a minimal
#       /boot/grub/grub.cfg suitable for -nographic boot.  This is
#       the every-Hurd-scenario path (inject when kernel.bin is
#       present; vanilla grub-only when it isn't).
#
#   SIDEKICK_OP=mkiso
#       Read /shared/iso-staging/ + /shared/iso-grub.cfg
#       (host-prepared), run grub-mkrescue, and write the result to
#       /shared/out.iso.  Used by the boot scenario on x86_64 to
#       bypass qemu's multiboot1 32-bit-ELF restriction.

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

# Parse kernel cmdline for SIDEKICK_OP.  Everything else the op
# needs comes via the 9p share (/shared) because Linux truncates
# the cmdline at COMMAND_LINE_SIZE (256 bytes on x86_64).
for arg in $(cat /proc/cmdline); do
  case "$arg" in
    SIDEKICK_OP=*) eval "$arg" ;;
  esac
done

SIDEKICK_OP=${SIDEKICK_OP:-}
case "$SIDEKICK_OP" in
  overlay-kernel)
    # Replace a kernel binary inside an attached qcow2 overlay with
    # /shared/kernel.bin AND regenerate grub.cfg.  The target kernel
    # path is auto-discovered from the disk's grub.cfg first
    # multiboot line — no need for the caller to know per-distro
    # paths (matters for Guix where the path includes a content
    # hash like /gnu/store/<hash>-gnumach-<ver>/boot/gnumach).
    # Distros that ship a gzipped kernel get the replacement
    # gzipped to match (path suffix .gz triggers this).
    for mod in virtio virtio_pci virtio_blk \
               sd_mod scsi_mod \
               ext2 ext4; do
      modprobe "$mod" 2>/dev/null
    done
    sleep 1

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

      # Flatten `configfile <path>` directives by inlining the
      # referenced file's contents.  Needed for Gentoo, which keeps
      # its module declarations in /boot/grub/entry_hurd.cfg and
      # pulls them in via `configfile` from each menuentry (so the
      # module chain is DRY across the GUI / serial / single-user
      # menu entries).  Debian inlines everything; no-op for it.
      #
      # One-level deep, no recursion guard — distros don't nest
      # configfile in practice.  Paths are absolute (rooted at the
      # disk's /), so we prefix /mnt to resolve them.
      flat_cfg=/tmp/grub-flat.cfg
      {
        while IFS= read -r line; do
          case "$line" in
            *configfile*)
              path=$(printf '%s\n' "$line" \
                | sed -nE 's|^[[:space:]]*configfile[[:space:]]+(.+)[[:space:]]*$|\1|p')
              if [ -n "$path" ] && [ -f "/mnt$path" ]; then
                cat "/mnt$path"
              else
                printf '%s\n' "$line"
              fi
              ;;
            *)
              printf '%s\n' "$line"
              ;;
          esac
        done < "$grub_cfg"
      } > "$flat_cfg"

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
          } else if (line ~ /^[A-Z][A-Z0-9_]*=[^[:space:]=]+$/) {
            # GRUB var assignment inside the menuentry body — e.g.
            # Gentoo: DISK=wd0 / PART=1 / DISKOPT=noide.  Keep so
            # that the subsequent multiboot ${DISK} etc. expand in
            # our regenerated menuentry.
            print "  " line
          }
        }
      ' "$flat_cfg")

      # Auto-discover the kernel path from the extracted boot recipe.
      # Field 2 of the first multiboot line is the kernel binary's
      # absolute path on the disk's fs (e.g. /boot/gnumach-1.8-486-up.gz
      # for Debian, /gnu/store/<hash>-gnumach.../boot/gnumach for Guix).
      # If /shared/kernel.bin is present, replace that file with ours
      # (gzip-wrap iff the path ends in .gz, matching what GRUB expects).
      kernel_path=$(printf '%s\n' "$boot_lines" \
        | awk '/^[[:space:]]*multiboot[[:space:]]/{print $2; exit}')
      kernel_path=${kernel_path#/}    # strip any leading /

      if [ -f /shared/kernel.bin ] && [ -n "$kernel_path" ]; then
        [ -e "/mnt/$kernel_path" ] \
          || { echo "FATAL: target kernel /mnt/$kernel_path missing — grub.cfg references a non-existent path?" >&2;
               sync; umount /mnt; poweroff -f; }
        case "$kernel_path" in
          *.gz) gzip -c < /shared/kernel.bin > "/mnt/$kernel_path" ;;
          *)    cp /shared/kernel.bin "/mnt/$kernel_path" ;;
        esac
      fi

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
  echo -e -n "\033[0m"
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
    echo "       supported: overlay-kernel, mkiso" >&2
    ;;
esac

# Clean shutdown — the host waits for qemu to exit and then reads
# the output files from its side of the 9p share.
sync
poweroff -f
