# Hurd cross-toolchain components — per-target derivations, built
# against the patched nixpkgs from pkgs.nix.
#
# Outputs:
#   hurd-binutils-<arch>     cross-binutils with target-prefixed
#                            binaries (`i686-gnu-as`, `i686-gnu-ld`, …).
#                            No hurd-side deps; safe to build first.
#   hurd-gcc-stage1-<arch>   gccWithoutTargetLibc — bare driver + cc1 +
#                            libgcc.a (no libgcc_s, no libstdc++, no
#                            libc dependency).  Enough to compile
#                            glibc-hurd (see glibc.nix).
#
# The final cross-cc (linked against glibc-hurd) and a wrapped
# stdenv.cc come in a later step, once glibc-hurd is in place.
#
# `hurdTargets` filters target-archs.nix to entries with a
# `hurdCrossSystem` field — today i686 and x86_64.  aarch64 is on
# Sergey Bugaev's branch (not upstream); xen variants share their
# non-xen sibling's userland ABI, so they're not duplicated here.

{ nixpkgs, mkHurdCrossPkgs }:

let
  lib = nixpkgs.lib;

  hurdTargets = targets:
    lib.filterAttrs (name: target: target ? hurdCrossSystem) targets;
in

{
  # mkHurdBinutils : system -> name -> target -> derivation
  # Cross-binutils for the given Hurd target.  Names the binary as
  # `<arch>-gnu-as` / `<arch>-gnu-ld` (via the lib.systems patch's
  # tripleFromSystem 2-tuple emission).
  mkHurdBinutils = system: name: target:
    (mkHurdCrossPkgs system target).buildPackages.binutils-unwrapped;

  # mkHurdGccStage1 : system -> name -> target -> derivation
  # Stage-1 cross-gcc: no libgcc_s, no libstdc++, no libc dependency.
  mkHurdGccStage1 = system: name: target:
    (mkHurdCrossPkgs system target).buildPackages.gccWithoutTargetLibc;

  # Per-target attrset the root flake merges into packages.<system>:
  # two outputs per target (binutils + gcc-stage1).  glibc-hurd is
  # merged separately in packages.nix (it needs its own srcInput +
  # Mach/Hurd headers).
  mkAll = system: targets:
    let
      hts = hurdTargets targets;
      pairs = lib.concatLists (lib.mapAttrsToList (name: target: [
        { name = "hurd-binutils-${name}";    value = (mkHurdCrossPkgs system target).buildPackages.binutils-unwrapped; }
        { name = "hurd-gcc-stage1-${name}";  value = (mkHurdCrossPkgs system target).buildPackages.gccWithoutTargetLibc; }
      ]) hts);
    in
    lib.listToAttrs pairs;
}
