#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# abi-level: auto
# Probe 25 - deployable-prefix (C-full) static acceptance.
# When the working glibc is built --prefix=/ (deployPrefix), a DEPLOYED Hurd
# has no /nix/store: every allocated section of every shipped ELF must be
# /nix/store-clean, no DT_RUNPATH/RPATH may point into the store, no FHS path
# may be double-slashed (the dir-knob regression - a missed --sysconfdir bakes
# //etc, etc.), and the augmented libc.so GROUP must be /-rooted.  This is the
# STATIC complement to the e2e boot gate.
#
# readelf (not strings/strip): the Hurd EI_OSABI ELF defeats the host BFD's
# strip, so strings-after-strip false-fails; readelf -p is format-agnostic.
# ALWAYS one file per readelf invocation - multiple files make readelf emit
# `File: <path>` headers, and that path is itself under /nix/store, which would
# false-trigger the store grep.
#
# Skips a store-coupled ($out-prefix) working glibc: its libc.so GROUP is
# store-rooted, so this probe doesn't apply (and the gate still runs every
# other probe against it).
set -u

W="$WORK/lib"
gso="$W/libc.so"
[ -f "$gso" ] && grep -q '^GROUP' "$gso" 2>/dev/null \
  || { echo "SKIP 25-deployable-prefix - $W/libc.so is not the Hurd GROUP ld-script"; exit 0; }
if grep '^GROUP' "$gso" | grep -q '/nix/store'; then
  echo "SKIP 25-deployable-prefix - libc.so GROUP is store-rooted (\$out-prefix glibc, not a deployable --prefix=/ build)"
  exit 0
fi

bad=""
# The shipped deployable ELFs (libc.so is the text GROUP script, checked below).
elfs="$W/libc.so.0.3 $(ls "$W"/ld*.so.* "$W"/lib*user.so.* "$W"/libpthread.so.* 2>/dev/null)"
for f in $elfs; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  # (1) zero /nix/store in allocated sections.
  [ "$("$CROSS_READELF" -p .dynstr -p .rodata "$f" 2>/dev/null | grep -c /nix/store)" = 0 ] \
    || bad="$bad $b(store)"
  # (2) no DT_RUNPATH/RPATH into the store.
  "$CROSS_READELF" -d "$f" 2>/dev/null | grep -E 'RUNPATH|RPATH' | grep -q /nix/store \
    && bad="$bad $b(runpath)"
  # (3) no double-slashed FHS path (a missed --prefix=/ dir knob); the only
  # legitimate // is the //www.gnu.org bug-report URL.
  "$CROSS_READELF" -p .dynstr -p .rodata "$f" 2>/dev/null \
    | grep -oE '//(etc|share|lib|var|run|sbin|bin|usr|opt)/' | grep -q . \
    && bad="$bad $b(//)"
done

# (4) the augmented libc.so GROUP is /-rooted with the Hurd RPC stubs.
grep '^GROUP' "$gso" | grep -q '/lib/libmachuser' || bad="$bad libc.so(GROUP-not-/-rooted)"

# (5) presence: the prefix retarget baked the /-rooted ld.so.cache path into the
# loader (proof the --sysconfdir=/etc knob took, not just that leaks are absent).
loader="$(ls "$W"/ld*.so.* 2>/dev/null | head -1)"
[ -n "$loader" ] && "$CROSS_READELF" -p .rodata "$loader" 2>/dev/null | grep -q '/etc/ld.so.cache' \
  || bad="$bad loader(no-/etc/ld.so.cache)"

if [ -n "$bad" ]; then
  echo "FAIL 25-deployable-prefix - store/non-/-rooted paths in shipped glibc:$bad"
  exit 1
fi
echo "PASS 25-deployable-prefix - shipped glibc ELFs /-clean (0 /nix/store, no store RUNPATH, no // FHS, GROUP /-rooted, /etc/ld.so.cache baked)"
