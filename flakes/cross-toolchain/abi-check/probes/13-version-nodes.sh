#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# abi-level: auto
# Probe 13 - version definition nodes (the .gnu.version_d set).  Catches a
# dropped or renamed version node, including the GLIBC_ABI_* gate nodes
# (e.g. GLIBC_ABI_DT_RELR) that abilist.awk discards unless run with
# include_abi_version=1 - so Tier-1 can't see them.
set -u
ref_so="$REF/lib/libc.so.0.3"; wrk_so="$WORK/lib/libc.so.0.3"
[ -f "$ref_so" ] && [ -f "$wrk_so" ] || { echo "SKIP 13-version-nodes - libc.so.0.3 not found"; exit 0; }
td="$PROBE_TMP/13"; mkdir -p "$td"

# The version names this library DEFINES (provider side).
defnodes() {
  "$CROSS_READELF" -W -V "$1" 2>/dev/null \
    | awk '/Version definition section/ {d=1} /Version needs section/ {d=0}
           d && match($0, /Name: [^ ]+/) {
             s = substr($0, RSTART+6); sub(/ .*/, "", s); print s }' \
    | grep -E '^(GLIBC_|HURD_|GCC_)' | LC_ALL=C sort -u
}
defnodes "$ref_so" > "$td/ref"
defnodes "$wrk_so" > "$td/wrk"
[ -s "$td/ref" ] || { echo "SKIP 13-version-nodes - no version definitions parsed"; exit 0; }

removed="$(comm -23 "$td/ref" "$td/wrk")"
if [ -n "$removed" ]; then
  echo "FAIL 13-version-nodes - version node(s) removed: $(printf '%s ' $removed)"
  exit 1
fi
added="$(comm -13 "$td/ref" "$td/wrk" | tr '\n' ' ')"
echo "PASS 13-version-nodes - no version nodes removed (added: ${added:-none})"
