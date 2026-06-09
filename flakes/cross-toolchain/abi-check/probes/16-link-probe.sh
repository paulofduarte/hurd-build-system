#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# abi-level: auto
# Probe 16 - turn "a symbol the reference exported is gone" into an actual
# *link* failure.  Tier-1 diffs symbol lists; this proves the working
# libc can still satisfy a link that references the reference's exported
# names.  Generates one extern reference per reference symbol and links a
# shared object against the working libc - a removed symbol -> link error.
set -u
ref_so="$REF/lib/libc.so.0.3"
[ -f "$ref_so" ] || { echo "SKIP 16-link-probe - reference libc.so.0.3 not found"; exit 0; }
[ -n "${CROSS_CC:-}" ] && [ -x "$CROSS_CC" ] || { echo "SKIP 16-link-probe - no cross cc"; exit 0; }
td="$PROBE_TMP/16"; mkdir -p "$td"

# Default-version (@@) function/object symbols the reference exports - the
# set a normal link binds.  C identifiers only (skip names with '.' etc.).
"$CROSS_READELF" -W --dyn-syms "$ref_so" 2>/dev/null \
  | awk '$7 != "UND" && $8 ~ /@@/ && ($4=="FUNC"||$4=="OBJECT") {
           n=$8; sub(/@@.*/,"",n); if (n ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print n }' \
  | LC_ALL=C sort -u > "$td/names"
n="$(wc -l < "$td/names" | tr -d ' ')"
[ "$n" -gt 0 ] || { echo "SKIP 16-link-probe - no default-version symbols extracted"; exit 0; }

# A TU that takes the address of every name, forcing the linker to bind
# each against the working libc.  `volatile` + array keeps them all live.
{
  awk '{print "extern char "$1";"}' "$td/names"
  echo "void *const __abi_probe_refs[] = {"
  awk '{print "  &"$1","}' "$td/names"
  echo "};"
} > "$td/probe.c"

# Link -shared against the WORKING libc only.  -nostdlib so we depend on
# nothing but what we explicitly point at.  -L"$WORK_LINK/lib" FIRST: it holds a
# probe-only libc.so whose GROUP members are BARE NAMES, resolved via the -L search
# path below, so ld resolves the deployable /lib GROUP with NO --sysroot (the
# wrapper strips --sysroot in-sandbox).  -L"$WORK/lib" supplies those named members
# (and is the $out-prefix-glibc fallback + the rpath-link source).
if err="$("$CROSS_CC" -shared -nostdlib -fPIC \
            -nostdinc -isystem "$WORK/include" \
            -L"${WORK_LINK:-$WORK}/lib" -L"$WORK/lib" -Wl,-rpath-link,"$WORK/lib" \
            "$td/probe.c" -lc -o "$td/probe.so" 2>&1)"; then
  echo "PASS 16-link-probe - all $n reference symbols resolve against the working libc"
else
  echo "FAIL 16-link-probe - link against working libc failed (removed/unresolved symbol):"
  printf '%s\n' "$err" | grep -iE 'undefined|not found|cannot' | sed 's/^/       /' | head -20
  exit 1
fi
