# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# IANA timezone database, compiled from source - replaces nixpkgs' pkgs.tzdata
# in dist-tzdata so the shipped zoneinfo is from-source like everything else.
#
# NATIVE build, one per host system: zic runs at BUILD time on the build host
# and emits arch-neutral TZif data, so a single native build serves every
# cross target (nothing here executes on Hurd).  Output layout matches what
# dist-tzdata already consumes: $out/share/zoneinfo (+ the .tab indexes).
#
# Version: the git repo carries no `version` file (release tarballs generate
# it, `make` in a checkout falls back to "unknown") and the pinned tag's NEWS
# heading can lag the tag itself (2026b's still says 2026a) - so the release
# ref IS the version, read back from flake.lock's `original.ref` exactly like
# flakes/sources does (nix doesn't expose the ref on a fetched input).
#
# Determinism (SOURCE_DATE_EPOCH plumbing, zic -b slim/fat choice) is
# deliberately deferred - repo policy: working first (as the rump stack was).

{
  nixpkgs,
  system,
  self,
  srcInput,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
  version = lock.nodes."tz-dep-src".original.ref or "unknown";
in
pkgs.stdenv.mkDerivation {
  pname = "tzdata";
  inherit version;
  src = srcInput;

  # No configure - the Makefile drives everything.  Point every install dir
  # except TZDIR into a scratch TOPDIR so ONLY the compiled zoneinfo lands in
  # $out (the tzselect/zic/zdump binaries, libtz.a and man pages are host
  # tools we don't ship); VERSION seeds the tzdata.zi/version stamps a git
  # checkout leaves "unknown".  REDO stays the posix_only default (the
  # standard distro main tree; no leap-second twin).
  dontConfigure = true;
  enableParallelBuilding = true;
  makeFlags = [
    "TOPDIR=discard"
    "TZDIR=${placeholder "out"}/share/zoneinfo"
    "VERSION=${version}"
  ];
  installTargets = [ "install" ];

  # Keep DWARF/rpath hygiene irrelevant: nothing ELF ships (only data).
  dontPatchELF = true;
  dontStrip = true;
  dontPatchShebangs = true;

  meta = with lib; {
    description = "IANA time zone database ${version} (from-source zoneinfo for the dist)";
    platforms = platforms.all;
    # tz code and data are public domain except a few BSD-3-Clause files
    # (see the LICENSE file in the source).
    license = with licenses; [
      publicDomain
      bsd3
    ];
  };
}
