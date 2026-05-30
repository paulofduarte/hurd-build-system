#!/usr/bin/env bash
# Compose / splice a local-source PACKAGE_VERSION matching the nix-built string
# (flakes/lib's composeVersion / composeFromParts) — with `-dirty` appended to
# the source-hash when src/<name> has uncommitted changes (the build-system
# tree's dirtiness was already covered on the build-hash component, both here
# and in the nix path).
#
# Usage:
#   local-version.sh print  <src-name>
#   local-version.sh splice <src-name>
#
# `print` echoes the composed string; `splice` rewrites src/<name>/version.m4
# or src/<name>/configure.ac in place ONLY IF the computed string differs from
# what's already there.  Steady-state (same commit, same dirty-set) is a no-op,
# so autoreconf does not re-fire on subsequent makes.
#
# Format consistency is enforced by handing every part — including the fork-id
# computed in nix — to `.#srcs.<name>.localVersion`, the same function the nix
# path uses (see flakes/sources/default.nix).
set -euo pipefail

cmd=${1:?usage: local-version.sh <print|splice> <src-name>}
name=${2:?usage: local-version.sh <print|splice> <src-name>}

buildroot=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
srcdir=$buildroot/src/$name
[ -d "$srcdir/.git" ] || {
  echo "local-version: $srcdir is not a git clone (run 'make srcs' first)" >&2
  exit 1
}

# Pick the autoconf input we splice into.  gnumach keeps the upstream version
# in version.m4 (m4_define([AC_PACKAGE_VERSION],[X])); mig keeps it inline in
# configure.ac (AC_INIT([GNU MIG], [X], …)).
if [ -f "$srcdir/version.m4" ]; then
  vfile=$srcdir/version.m4
  vfile_rel=version.m4
  extract_re='s/^m4_define(\[AC_PACKAGE_VERSION\],\[\([^]]*\)\]).*/\1/p'
  splice_re='s|m4_define(\[AC_PACKAGE_VERSION\],\[[^]]*\])|m4_define([AC_PACKAGE_VERSION],[NEWVER])|'
elif [ -f "$srcdir/configure.ac" ]; then
  vfile=$srcdir/configure.ac
  vfile_rel=configure.ac
  extract_re='s/^AC_INIT(\[[^]]*\], \[\([^]]*\)\],.*/\1/p'
  splice_re='s|^AC_INIT(\(\[[^]]*\]\), \[[^]]*\], |AC_INIT(\1, [NEWVER], |'
else
  echo "local-version: $srcdir has no version.m4 or configure.ac" >&2
  exit 1
fi

raw=$(sed -n "$extract_re" "$vfile" | head -1)
# The version file may already carry a prior splice — recover the original
# upstream string (1.8) from either form: "1.8" or "v1.8+git…+build.g…".
case $raw in
  v*+git*) upstream=$(printf '%s' "$raw" | sed -e 's|^v||' -e 's|\+git.*||') ;;
  *)       upstream=${raw:-unknown} ;;
esac

src_short=$(git -C "$srcdir" rev-parse --short HEAD 2>/dev/null || echo unknown)
src_date=$(git -C "$srcdir" log -1 --format=%cd --date=format:%Y%m%d HEAD 2>/dev/null \
           || echo 00000000)

# Dirty-check excludes the version file itself — our own splice would otherwise
# self-toggle the `-dirty` flag on every other build.
if [ -n "$(git -C "$srcdir" status --porcelain -- . ":!$vfile_rel" 2>/dev/null)" ]; then
  src_dirty=true
else
  src_dirty=false
fi

build_short=$(git -C "$buildroot" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$buildroot" status --porcelain 2>/dev/null)" ]; then
  build_dirty=true
else
  build_dirty=false
fi

# Hand the parts to .#srcs.<name>.localVersion — same composer the nix-built
# derivations use, so the format stays in lockstep across both paths.
newver=$(cd "$buildroot" && \
  nix --extra-experimental-features 'nix-command flakes' eval --raw \
    ".#srcs.${name}.localVersion" --apply "f: f {
      upstreamVersion = \"${upstream}\";
      srcShort        = \"${src_short}\";
      srcDate         = \"${src_date}\";
      srcDirty        = ${src_dirty};
      buildShort      = \"${build_short}\";
      buildDirty      = ${build_dirty};
    }")

case $cmd in
  print)
    echo "$newver"
    ;;
  splice)
    [ "$raw" = "$newver" ] && exit 0
    # `&` is special in sed replacements; escape it defensively.  `|` is the
    # delimiter — a version string containing `|` would break, but the format
    # forbids it.
    escaped=$(printf '%s' "$newver" | sed -e 's/[&]/\\&/g')
    expr=${splice_re//NEWVER/$escaped}
    sed -i.bak "$expr" "$vfile"
    rm -f "$vfile.bak"
    echo "  VERSION  src/$name/$vfile_rel  $newver"
    ;;
  *)
    echo "local-version: unknown command '$cmd'" >&2
    exit 2
    ;;
esac
