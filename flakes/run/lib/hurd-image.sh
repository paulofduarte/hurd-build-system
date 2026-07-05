# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Offline Hurd image population - sourced by run scenarios (no exec).
#
# Writes the passive-translator records + device nodes + ownership DIRECTLY
# into the ext2 image with debugfs, replacing the guest-side first-boot
# MAKEDEV bootstrap entirely: our hurd's ext2fs reads translator records
# from the standard `gnu.translator` extended attribute (ext2fs/inode.c -
# xattr records are the DEFAULT store since the xattr work; the legacy
# i_translator block field is the fallback), and ext2 EAs are plain
# e2fsprogs territory - so image assembly stays fully offline, hostless and
# deterministic (zero guest execution).
#
# The node table transliterates sutils/MAKEDEV.sh's `st` recipes (translator
# argz, node type, mode) - see hurd_image_populate below.  Passive
# translators are LAZY name->server mappings, so the table can carry the
# full superset of plausible hardware (hd*/wd* for both the in-kernel and
# rumpdisk storage paths); absent-device nodes cost an inode and never
# start.  One populated image is hardware-portable.
#
# debugfs gotchas baked in:
#   - mknod must be cd-RELATIVE: an absolute path allocates the inode but
#     silently fails to link it into the parent;
#   - ea_set -f takes the value from a FILE (argz values embed NULs);
#   - sif mode wants the FULL mode including the S_IF* type bits (a bare
#     permission value would clear the type);
#   - everything debugfs creates is uid 0/gid 0 - and a generated sif pass
#     normalises the mke2fs -d tree (which stamps the BUILD HOST's uid on
#     every inode; passive translators run AS THE NODE'S OWNER, so a
#     non-root /servers/password could not mint root credentials).

# hurd_image_mknode DIR NAME TYPE MODE [TRANSLATOR ARGS...]
#   Queue one node: TYPE c(har)/b(lock)/d(ir)/f(ile - must already exist in
#   the tree), MODE octal permissions (type bits added here).  TRANSLATOR
#   args become the gnu.translator argz.  Appends to the debugfs script +
#   value files under $_HI_TMP; run by hurd_image_flush.
hurd_image_mknode() {
  local dir="$1" name="$2" type="$3" mode="$4"
  shift 4
  local path="$dir/$name"
  local typebits
  case "$type" in
    c) typebits=020000 ;;
    b) typebits=060000 ;;
    d) typebits=040000 ;;
    f) typebits=100000 ;;
    *) die "hurd_image_mknode: bad type $type for $path" ;;
  esac
  case "$type" in
    c | b) printf 'cd %s\nmknod %s %s 0 0\n' "$dir" "$name" "$type" >>"$_HI_SCRIPT" ;;
    d) printf 'mkdir %s\n' "$path" >>"$_HI_SCRIPT" ;;
    f) : ;; # plain file: staged in the tree already (mke2fs -d)
  esac
  if [ $# -gt 0 ]; then
    local vf
    vf="$_HI_TMP/trans-$(printf '%s' "$path" | tr '/' '_').bin"
    printf '%s\0' "$@" >"$vf"
    printf 'ea_set -f %s %s gnu.translator\n' "$vf" "$path" >>"$_HI_SCRIPT"
  fi
  printf 'sif %s mode %o\n' "$path" "$((typebits | mode))" >>"$_HI_SCRIPT"
}

# hurd_image_symlink DIR NAME TARGET
hurd_image_symlink() {
  printf 'symlink %s/%s %s\n' "$1" "$2" "$3" >>"$_HI_SCRIPT"
}

# hurd_image_populate IMG ROOTFS TMPDIR
#   The declarative population: ownership normalisation for the whole tree
#   + the /dev + /servers node table.  ROOTFS is the staging tree the image
#   was mke2fs -d'd from (used to enumerate files for the uid/gid pass).
hurd_image_populate() {
  local img="$1" rootfs="$2"
  _HI_TMP="$3"
  _HI_SCRIPT="$_HI_TMP/populate.dbg"
  : >"$_HI_SCRIPT"

  # Ownership: everything root:root (see header).  Enumerate the staged
  # tree; the nodes created below are debugfs-born root already.
  (cd "$rootfs" && find . -mindepth 1 \( -type f -o -type d -o -type l \)) |
    sed 's|^\.||' |
    while IFS= read -r p; do
      printf 'sif %s uid 0\nsif %s gid 0\n' "$p" "$p" >>"$_HI_SCRIPT"
    done

  # --- /dev: MAKEDEV std, transliterated from sutils/MAKEDEV.sh ---
  hurd_image_mknode /dev console c 600 /hurd/term /dev/console device console
  hurd_image_mknode /dev tty c 666 /hurd/magic tty
  hurd_image_mknode /dev null c 666 /hurd/null
  hurd_image_mknode /dev full c 666 /hurd/null --full
  hurd_image_mknode /dev zero c 666 /bin/nullauth -- /hurd/storeio -Tzero
  hurd_image_mknode /dev random c 644 /hurd/random --seed-file /var/lib/random-seed
  hurd_image_symlink /dev urandom random
  hurd_image_mknode /dev fd d 666 /hurd/magic --directory fd
  hurd_image_symlink /dev stdin fd/0
  hurd_image_symlink /dev stdout fd/1
  hurd_image_symlink /dev stderr fd/2
  hurd_image_mknode /dev time c 644 /hurd/storeio --no-cache time
  hurd_image_mknode /dev mem c 660 /hurd/storeio --no-cache mem
  hurd_image_mknode /dev klog c 660 /hurd/streamio kmsg
  hurd_image_symlink /dev shm /tmp # MAKEDEV parity (tmpfs open issue)

  # Disks: the full superset for BOTH storage paths - in-kernel hd* (i686
  # phase 3) and rumpdisk wd* (phase 5).  Lazy translators: nodes for
  # absent hardware never start (hardware-portable image).
  local d n
  for d in hd wd sd; do
    for n in 0 1 2 3; do
      hurd_image_mknode /dev "$d$n" b 640 /hurd/storeio "$d$n"
      local s
      for s in 1 2 3 4; do
        hurd_image_mknode /dev "${d}${n}s${s}" b 640 \
          /hurd/storeio -T typed "part:$s:device:$d$n"
      done
    done
  done

  # --- /servers: the translator seats that must WORK, not just exist.
  # password: login's auth RPC needs /hurd/password minting credentials.
  # socket/1: pflocal (pipes) - CHAR-typed (runsystem's install-case check
  # is `test -c`), created here so its self-heal (settrans + rw remount
  # dance) never fires.  crash: post-boot crash dumps.  The plain seats
  # (exec, startup, proc, ...) are touched in the staging tree by the
  # scenario - they only have to exist.
  hurd_image_mknode /servers password f 644 /hurd/password
  hurd_image_mknode /servers/socket 1 c 666 /hurd/pflocal
  hurd_image_mknode /servers crash f 644 /hurd/crash

  echo "  POPULATE  $img (offline: $(grep -c ea_set "$_HI_SCRIPT") translators, tree ownership -> root)"
  debugfs -w -f "$_HI_SCRIPT" "$img" >"$_HI_TMP/populate.log" 2>&1
  # debugfs exits 0 even on per-command failure - grep the log for trouble.
  if grep -qE 'not found|Could not|failed|invalid' "$_HI_TMP/populate.log"; then
    die "offline population had failures - see $_HI_TMP/populate.log"
  fi
}
