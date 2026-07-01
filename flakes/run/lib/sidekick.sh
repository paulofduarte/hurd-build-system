# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Host-side orchestrator for the option-1 boot path.
#
# All the logic lives HERE, on the host (identical on Linux + darwin); it only
# calls the two ATOMIC, transparent sidekick tools — native on Linux, forwarded by
# `sidekick-run` on darwin (resolved on PATH via the dev shell):
#   sidekick-imgcp <image> <raw|qcow2> <src> <dest>  copy a file out of an image
#   sidekick-mkrescue -o <iso> <dir>                 build an x86 BIOS GRUB ISO
# No VM logic, no kernel/initrd artefacts. Paths stay under work/, so they are the
# same path the guest sees over virtiofs.
#
# Operations:
#   sidekick_make_iso   <out_iso> <staging> <grub_cfg> [cache_key]
#       Wrap a staging dir + grub.cfg into a GRUB ISO (the `boot` scenario).
#   sidekick_distro_iso <out_iso> <disk> <fmt> [<our_gnumach>]
#       Build an option-1 ISO for a Hurd distro image: read its grub.cfg and emit
#       an ISO that boots <our_gnumach> (empty => the distro's own kernel, i.e.
#       vanilla) while pulling the Hurd modules + root from the UNMODIFIED disk via
#       `search --fs-uuid`.

# Build the ISO via sidekick-mkrescue, surfacing its stderr on failure.  On
# darwin the tool runs in the guest over ssh; a swallowed error there is opaque
# (e.g. a staging path the guest can't see, or missing xorriso/mtools), so on
# failure we replay the captured log before dying.
_mkrescue() {
  local out_iso="$1" iso_root="$2" log
  log="$(dirname "$out_iso")/mkrescue.log"
  if ! sidekick-mkrescue -o "$out_iso" "$iso_root" >"$log" 2>&1; then
    echo "sidekick: grub-mkrescue failed building $out_iso" >&2
    sed 's/^/  | /' "$log" >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}

# sidekick_make_iso <out_iso> <staging_dir> <grub_cfg_text> [cache_key]
#   Content-addressed on (cache_key, grub_cfg).
sidekick_make_iso() {
  local out_iso="$1" staging="$2" grub_cfg="$3" cache_key="${4:-}"
  local stamp="$out_iso.stamp" hash
  hash=$(printf '%s\n%s' "$cache_key" "$grub_cfg" | sha256_stdin)
  if [ -f "$out_iso" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$hash" ]; then return 0; fi
  echo "sidekick: assembling GRUB ISO from $(basename "$staging") ..." >&2
  local work
  work="$(dirname "$out_iso")/iso-build"
  rm -rf "$work"
  mkdir -p "$work/iso-root/boot/grub"
  cp -a "$staging/." "$work/iso-root/"
  printf '%s\n' "$grub_cfg" >"$work/iso-root/boot/grub/grub.cfg"
  _mkrescue "$out_iso" "$work/iso-root" || die "sidekick: ISO build failed ($out_iso)"
  rm -rf "$work"
  [ -s "$out_iso" ] || die "sidekick: ISO build produced nothing ($out_iso)"
  printf '%s' "$hash" >"$stamp"
}

# sidekick_distro_iso <out_iso> <disk> <fmt> [<our_gnumach>]
sidekick_distro_iso() {
  local out_iso="$1" disk="$2" fmt="$3" gnumach="${4:-}"
  local stamp="$out_iso.stamp"
  # Reuse iff the ISO exists, the gnumach selection is unchanged, and neither the
  # disk nor our gnumach is newer than the stamp.
  if [ -f "$out_iso" ] && [ -f "$stamp" ] &&
    [ "$(cat "$stamp")" = "$gnumach" ] &&
    [ ! "$disk" -nt "$stamp" ] &&
    { [ -z "$gnumach" ] || [ ! "$gnumach" -nt "$stamp" ]; }; then
    return 0
  fi
  if [ -n "$gnumach" ]; then
    echo "sidekick: building boot ISO (our gnumach + $(basename "$disk")'s Hurd, disk untouched) ..." >&2
  else
    echo "sidekick: building boot ISO ($(basename "$disk")'s own kernel, disk untouched) ..." >&2
  fi

  local work
  work="$(dirname "$out_iso")/iso-build"
  rm -rf "$work"
  mkdir -p "$work/iso-root/boot/grub"

  # 1. read the distro grub.cfg + flatten one-level `configfile` includes
  sidekick-imgcp "$disk" "$fmt" /boot/grub/grub.cfg "$work/distro.cfg" ||
    die "sidekick: could not read /boot/grub/grub.cfg from $disk"
  : >"$work/flat.cfg"
  while IFS= read -r line; do
    case "$line" in
      *configfile*)
        local inc
        inc=$(printf '%s\n' "$line" | sed -nE 's|^[[:space:]]*configfile[[:space:]]+(.+)[[:space:]]*$|\1|p')
        if [ -n "$inc" ] && sidekick-imgcp "$disk" "$fmt" "$inc" "$work/inc.cfg" 2>/dev/null; then
          cat "$work/inc.cfg" >>"$work/flat.cfg"
        else
          printf '%s\n' "$line" >>"$work/flat.cfg"
        fi
        ;;
      *) printf '%s\n' "$line" >>"$work/flat.cfg" ;;
    esac
  done <"$work/distro.cfg"

  # 2. the distro's own root-setting `search` line (reused verbatim) + the boot
  #    recipe (multiboot + module lines, `\`-joined, serial forced onto multiboot).
  #    Reusing the search line handles every dialect + every `--set` form:
  #    Debian `--fs-uuid --set=root <uuid>`, Gentoo `--set=root --file <path>`,
  #    Guix `--fs-uuid --set <uuid>` (bare --set defaults the var to root).
  #    `--hint-*` device hints are stripped (BIOS/EFI device numbering differs in
  #    our ISO boot context; GRUB then full-scans, which is what we want).
  local search_line boot_lines
  search_line=$(grep -m1 -E '^[[:space:]]*search[[:space:]].*--set' "$work/flat.cfg" |
    sed -E 's/^[[:space:]]*//; s/[[:space:]]+--hint-[^[:space:]]*//g; s/[[:space:]]+/ /g')
  [ -n "$search_line" ] || die "sidekick: no root-setting 'search' line in the distro grub.cfg"
  #    Also keep grub VARIABLE ASSIGNMENTS (set VAR= / VAR=value) from the menuentry
  #    body: Gentoo x86_64's `DISK=wd0 PART=1 DISKOPT=noide` feed the multiboot's
  #    root=part:${PART}:device:${DISK} ${DISKOPT} - drop them and root goes empty
  #    (`part::device:` -> ext2fs: Invalid argument). (i686's image inlined literals.)
  boot_lines=$(awk '
    /^menuentry / && !/recovery mode/ && !found { found=1; in_body=1; prev=""; next }
    in_body && /^}/ { if (prev != "") emit(prev); exit }
    in_body {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, " ", line); prev = prev line; next }
      if (prev != "") { prev = prev line; emit(prev); prev = "" } else { emit(line) }
    }
    function emit(l) {
      if (l ~ /^multiboot[[:space:]]/) { if (l !~ /console=com0/) l = l " console=com0"; print "  " l }
      else if (l ~ /^module[[:space:]]/) { print "  " l }
      else if (l ~ /^set[[:space:]]/ || l ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { print "  " l }
    }
  ' "$work/flat.cfg")
  [ -n "$boot_lines" ] || die "sidekick: no multiboot/module lines in the distro grub.cfg"

  # 3. construct the ISO grub.cfg (our gnumach from the ISO, modules + root from
  #    the disk via search --fs-uuid; vanilla keeps the distro kernel from disk)
  {
    cat <<EOF
set timeout=0
serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial
# Pin GRUB's palette: its default color_highlight is black-on-WHITE, which on a
# serial terminal emits a white-background ANSI sequence that bleeds past GRUB
# into the kernel's console output. Force dark backgrounds on both.
set color_normal=light-gray/black
set color_highlight=white/black
menuentry "hurd" {
  insmod part_msdos
  insmod ext2
EOF
    if [ -n "$gnumach" ]; then
      cp -L "$gnumach" "$work/iso-root/boot/gnumach"
      # grub var assignments (Gentoo's DISK=/PART=/DISKOPT=) first, so the ${vars}
      # in our multiboot args below resolve.
      printf '%s\n' "$boot_lines" |
        awk '/^[[:space:]]*(set[[:space:]]|[A-Za-z_][A-Za-z0-9_]*=)/'
      local margs
      margs=$(printf '%s\n' "$boot_lines" |
        awk '/^[[:space:]]*multiboot[[:space:]]/{ $1=""; $2=""; sub(/^[[:space:]]+/, ""); print; exit }')
      printf '  multiboot /boot/gnumach %s\n' "$margs"
      printf '  %s\n' "$search_line"
      printf '%s\n' "$boot_lines" | awk '/^[[:space:]]*module[[:space:]]/'
    else
      printf '  %s\n' "$search_line"
      printf '%s\n' "$boot_lines"
    fi
    printf '}\n'
  } >"$work/iso-root/boot/grub/grub.cfg"

  # 4. assemble the BIOS ISO
  _mkrescue "$out_iso" "$work/iso-root" || die "sidekick: ISO build failed ($out_iso)"
  rm -rf "$work"
  [ -s "$out_iso" ] || die "sidekick: ISO build produced nothing ($out_iso)"
  printf '%s' "$gnumach" >"$stamp"
}
