# Per-target toolchain paths + triples, computed ONCE so the nix glibc build
# (glibc.nix) and the in-tree dev shell (dev-shell.nix) derive `--with-binutils`,
# `--build` and `--host` from a single source instead of repeating the same
# expressions.  There is only one cross-binutils (binutils-unwrapped); both sides
# get its `/bin` from here, so `--with-binutils` is genuinely DRY (same store path).
{ nixpkgs, mkCrossPkgs }:

system: target:
let
  pkgs      = nixpkgs.legacyPackages.${system};
  crossPkgs = mkCrossPkgs system target;
  binutils  = crossPkgs.buildPackages.binutils-unwrapped;
in {
  inherit binutils;                              # the derivation (for AR/AS/LD/… tool paths)
  binutilsBin = "${binutils}/bin";               # --with-binutils
  buildTriple = pkgs.stdenv.hostPlatform.config; # --build (the build-host triple)
  hostTriple  = target.crossTarget;              # --host (the <cpu>-gnu target)
}
