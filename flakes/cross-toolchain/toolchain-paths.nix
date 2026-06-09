# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Per-target toolchain paths + triples (--with-binutils / --build / --host), shared
# by glibc.nix and the dev shell so the nix and in-tree builds use the same values.
{ nixpkgs, mkCrossPkgs }:

system: target:
let
  pkgs      = nixpkgs.legacyPackages.${system};
  crossPkgs = mkCrossPkgs system target;
  binutils  = crossPkgs.buildPackages.binutils-unwrapped;
in {
  inherit binutils;                              # the derivation (for AR/AS/LD/... tool paths)
  binutilsBin = "${binutils}/bin";               # --with-binutils
  buildTriple = pkgs.stdenv.hostPlatform.config; # --build (the build-host triple)
  hostTriple  = target.crossTarget;              # --host (the <cpu>-gnu target)
}
