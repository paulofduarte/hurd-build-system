# lib/systems extension to re-enable GNU Hurd cross-compilation.
#
# nixpkgs carried a `hurd` kernel + `isHurd` predicate from ~2012 to
# 2018; PR #45721 removed it.  Stock nixpkgs 25.11 will not even PARSE
# `i686-gnu` - the parser's `getKernel` throws on the unknown kernel.
#
# This module re-applies the missing pieces (kernels.hurd, parser
# allow-list, isHurd predicate, libc cascade, hasSharedLibraries,
# uname.system) as a patch over the pinned nixpkgs source.  The patch
# is purely additive - builds that don't target Hurd are unaffected.
#
# Why a patch and not `lib.extend`: parse.mkSystemFromSkeleton captures
# the `kernels` attrset in a file-local `let`, and `elaborate` is built
# the same way, so extending the published attribute doesn't reach
# those closures.  Reimplementing them from outside would copy hundreds
# of lines that break on every nixpkgs bump.
#
# flakes/cross-toolchain (mkCrossPkgs) consumes the patched source for
# everything it cross-builds - the gnumach kernel, mig, glibc-hurd, and
# the Hurd userland; sidekick keeps using vanilla nixpkgs.
#
# API:
#   patchedNixpkgsSrc { system }   store path to a patched nixpkgs
#                                  source, a drop-in for `import`.
#   probe { system, config }       elaborate a config against the
#                                  patched lib (pure eval, no build).

{ nixpkgs }:

let
  patches = [
    ./patches/01-add-hurd-kernel.patch
  ];
in

{
  inherit patches;

  # Build a patched nixpkgs source path for a given build host.  Pure
  # derivation; cached after the first build.  Callers import it with a
  # crossSystem, e.g.:
  #   import (patchedNixpkgsSrc { inherit system; }) {
  #     localSystem.system = system; crossSystem.config = "i686-gnu";
  #   }
  patchedNixpkgsSrc = { system }:
    let pkgs = import nixpkgs { localSystem.system = system; };
    in pkgs.applyPatches {
      name = "nixpkgs-hurd-systems";
      src = nixpkgs;
      inherit patches;
    };

  # Elaborate a config string against the patched lib - a pure-eval
  # helper for checking the patch resolves a triplet (kernel, libc,
  # isHurd, ...) without building anything.
  probe = { system, config }:
    let
      patched = (import nixpkgs { localSystem.system = system; }).applyPatches {
        name = "nixpkgs-hurd-systems-probe";
        src = nixpkgs;
        inherit patches;
      };
      libPatched = (import (patched + "/lib")).systems;
    in
    libPatched.elaborate { inherit config; };
}
