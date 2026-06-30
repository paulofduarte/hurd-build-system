#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Copy ONE file out of a (partitioned) Hurd disk image — an atomic, unprivileged
# "cp from a disk image" primitive. NO orchestration: the host decides which files
# to pull and what to do with them; this just reads one.
#
#   sidekick-imgcp <image> <raw|qcow2> <src-path-in-image> <dest-on-host>
#
# The image is exposed read-only as a raw FUSE view (qemu-storage-daemon — debugfs
# can't read the qcow2 container, and we use it uniformly for raw too), then the
# ext partition holding <src> is found and the file dumped out with debugfs. The
# image is never modified. All tools come from PATH (native on Linux; forwarded by
# sidekick-run on darwin).
set -euo pipefail

img=$1
fmt=$2
src=$3
dest=$4

work=$(mktemp -d)
sd=
sd_log=$work/sd.log
view=$work/rawview
# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() {
  [ -n "$sd" ] && kill "$sd" 2>/dev/null || true
  fusermount3 -u "$view" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

case "$fmt" in
  raw | qcow2) ;;
  *)
    echo "sidekick-imgcp: unknown format '$fmt' (want raw|qcow2)" >&2
    exit 1
    ;;
esac

# read-only raw FUSE view of the image (no copy; image untouched)
: >"$view"
qemu-storage-daemon \
  --blockdev "driver=$fmt,node-name=d,file.driver=file,file.filename=$img" \
  --export "type=fuse,id=e,node-name=d,mountpoint=$view,writable=off,allow-other=off" 2>"$sd_log" &
sd=$!
for _ in $(seq 1 50); do
  [ -s "$view" ] && break
  kill -0 "$sd" 2>/dev/null || break # daemon already gave up
  sleep 0.2
done
[ -s "$view" ] || {
  echo "sidekick-imgcp: could not expose $(basename "$img") as a raw FUSE view." >&2
  [ -s "$sd_log" ] && sed 's/^/  | /' "$sd_log" >&2
  echo "sidekick-imgcp: this needs non-root FUSE — qemu-storage-daemon mounts a FUSE" >&2
  echo "  export, which on Linux requires a setuid fusermount3 that libfuse can reach." >&2
  echo "  NixOS provides /run/wrappers/bin/fusermount3; on other distros install fuse3" >&2
  echo "  and ensure fusermount3 is setuid-root and on PATH. /dev/fuse must also be" >&2
  echo "  accessible. (The sidekick guest sets this up; a native Linux host must too.)" >&2
  exit 1
}

# find the ext partition that holds <src> and dump the file out
while read -r start; do
  off=$((start * 512))
  if debugfs -R "stat $src" "$view?offset=$off" >/dev/null 2>&1; then
    debugfs -R "dump $src $dest" "$view?offset=$off" 2>/dev/null
    [ -e "$dest" ] && exit 0
  fi
done < <(sfdisk -d "$view" 2>/dev/null | sed -nE 's/.*start=[[:space:]]*([0-9]+).*/\1/p')

echo "sidekick-imgcp: '$src' not found in any partition of $img" >&2
exit 1
