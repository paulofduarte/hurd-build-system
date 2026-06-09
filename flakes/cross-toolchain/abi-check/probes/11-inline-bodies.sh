#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# abi-level: auto
# Probe 11 - static-inline / fortify shim bodies + signatures.  glibc
# ships `static __inline__` wrappers and `_FORTIFY_SOURCE` shims whose
# *bodies* are compiled into callers - change one and every caller
# rebuilt against the new header gets different code, with no symbol or
# DWARF change in libc.so.  Preprocess a fixed TU that pulls the
# fortify-prone headers, pinned flags, and diff the expansion.
set -u
td="$PROBE_TMP/11"; mkdir -p "$td"

cat > "$td/tu.c" <<'EOF'
#define _FORTIFY_SOURCE 2
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
EOF

gen() { # $1 = sysroot root -> preprocessed-and-normalized inline surface
  local root="$1"
  # -P drops line markers; -O2 -D_FORTIFY_SOURCE=2 is the realistic
  # caller config where the fortify inlines actually expand.  -isystem
  # (not -nostdinc - glibc headers need the compiler's resource headers
  # via include_next).  Strip blank lines so cosmetic whitespace doesn't
  # trip the diff.
  "$CROSS_CC" -E -P -O2 -D_FORTIFY_SOURCE=2 -isystem "$root/include" \
      -x c "$td/tu.c" 2>/dev/null \
    | grep -vE '^[[:space:]]*$'
}
gen "$REF"  > "$td/ref"
gen "$WORK" > "$td/wrk"
[ -s "$td/ref" ] || { echo "SKIP 11-inline-bodies - could not preprocess fortify TU"; exit 0; }

if ! diff -q "$td/ref" "$td/wrk" >/dev/null; then
  echo "FAIL 11-inline-bodies - inline/fortify expansion changed (< ref, > working):"
  diff "$td/ref" "$td/wrk" | grep -E '^[<>]' | sed 's/^/       /' | head -25
  exit 1
fi
echo "PASS 11-inline-bodies - static-inline / fortify shim bodies unchanged"
