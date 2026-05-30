# Cross-toolchain derivation + the DWARF prefix-map flags that go with it.
#
# `mkToolchain` is the single definition of "the toolchain" — the wrapped
# cross `cc`, whose closure is the patched binutils + newlib.  Exposed as
# `packages.<sys>.toolchain-<arch>` so the cache workflow + cache-hit
# planner reference that output rather than reaching into stdenv.cc.
#
# `mkReproDebugFlags` is the matching string of `-fdebug-prefix-map=…`
# entries that rewrite nix-store paths for that toolchain to stable
# `/cross-*` names in DWARF.  Used by both the nix-built gnumach/mig
# derivations (baked into CFLAGS) and — via the `reproDebugFlags.<sys>.<arch>`
# flake output — the in-tree `make mach` build.  Single source of truth
# for "what nix's toolchain DWARF rewrites look like."

{ nixpkgs, mkCrossPkgs }:

{
  mkToolchain = system: target: (mkCrossPkgs system target).stdenv.cc;

  mkReproDebugFlags = system: target:
    let cc = (mkCrossPkgs system target).stdenv.cc;
    in builtins.concatStringsSep " " [
      "-fdebug-prefix-map=${cc}=/cross-cc-wrapper"
      "-fdebug-prefix-map=${cc.cc}=/cross-gcc"
      "-fdebug-prefix-map=${cc.bintools}=/cross-binutils-wrapper"
    ];
}
