#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# abi-level: full
# Probe 24 - packing / alignment drift in ABI-critical public structs, via
# `pahole` on the unstripped ref+working libc.  Complements Tier-2: abidiff
# reports member-offset changes but pahole also surfaces hole/padding and
# alignment shifts that can change layout without moving a named member.
set -u
ref_so="$REF/lib/libc.so.0.3"; wrk_so="$WORK/lib/libc.so.0.3"
[ -f "$ref_so" ] && [ -f "$wrk_so" ] || { echo "SKIP 24-pahole-layout - libc.so.0.3 not found"; exit 0; }
command -v pahole >/dev/null 2>&1 || { echo "SKIP 24-pahole-layout - pahole not on PATH"; exit 0; }
td="$PROBE_TMP/24"; mkdir -p "$td"

structs='stat stat64 timespec timeval tm sigaction dirent dirent64
         sockaddr sockaddr_in sockaddr_in6 msghdr iovec rlimit rusage
         termios flock pollfd _IO_FILE __pthread_mutex_s'

fails=()
tested=0
for s in $structs; do
  r="$(pahole -C "$s" "$ref_so" 2>/dev/null)"
  w="$(pahole -C "$s" "$wrk_so" 2>/dev/null)"
  [ -z "$r" ] && [ -z "$w" ] && continue          # struct not in either (skip)
  tested=$((tested+1))
  if [ "$r" != "$w" ]; then
    fails+=("$s")
    { echo "== $s =="; diff <(printf '%s\n' "$r") <(printf '%s\n' "$w"); } >> "$td/diff.txt"
  fi
done
[ "$tested" -gt 0 ] || { echo "SKIP 24-pahole-layout - none of the curated structs carry DWARF"; exit 0; }

if [ "${#fails[@]}" -ne 0 ]; then
  echo "FAIL 24-pahole-layout - layout/packing changed in: ${fails[*]}"
  sed 's/^/       /' "$td/diff.txt" | head -40
  exit 1
fi
echo "PASS 24-pahole-layout - $tested curated public structs layout-identical"
