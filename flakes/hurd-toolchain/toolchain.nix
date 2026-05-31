# Hurd cross-toolchain components — per-target derivations, built
# against the patched nixpkgs from pkgs.nix.
#
# Outputs:
#   hurd-binutils-<arch>     cross-binutils with target-prefixed
#                            binaries (`i686-gnu-as`, `i686-gnu-ld`, …).
#                            No hurd-side deps; safe to build first.
#   hurd-gcc-stage1-<arch>   gccWithoutTargetLibc — bare driver + cc1 +
#                            libgcc.a (no libgcc_s, no libstdc++, no
#                            libc dependency).  Compiles glibc-hurd.
#   hurd-gcc-<arch>          final cross-gcc: C + C++, libgcc_s and
#                            libstdc++ linked against glibc-hurd.  Same
#                            nixpkgs gcc builder as stage-1, flipped via
#                            withoutTargetLibc=false + libcCross.
#   hurd-toolchain-<arch>    the wrapped cross-cc (cc-wrapper around the
#                            final gcc + glibc-hurd + a glibc-hurd-wrapped
#                            binutils) — the attribute downstream
#                            consumers use in mkDerivation.
#
# `mkAll` emits the pre-libc components (binutils + stage-1).  The final
# gcc + wrapped toolchain need glibc-hurd, so `mkFinal` takes the
# glibc-hurd attrset and is invoked from packages.nix after glibc-hurd
# is built.
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

  # The final cross-gcc: nixpkgs' own gcc builder with the target libc
  # present (withoutTargetLibc=false) so it builds libgcc_s + libstdc++,
  # C++ enabled, shared libs on.  Reusing the stage-1 cc's `.override`
  # keeps every nixpkgs gcc patch/phase; only the libc-facing knobs flip.
  finalGcc = system: target: glibcHurd:
    (mkHurdCrossPkgs system target).buildPackages.gccWithoutTargetLibc.cc.override {
      withoutTargetLibc = false;
      langCC            = true;
      libcCross         = glibcHurd;
      enableShared      = true;
    };

  # The wrapped cross-cc.  Both the cc-wrapper and the bintools-wrapper
  # are pointed at glibc-hurd; using the glibc-hurd-wrapped binutils
  # (rather than the default cross binutils wrapper) avoids dragging in
  # nixpkgs' own glibc, whose meta.platforms gate refuses the Hurd
  # target at eval time.
  wrappedToolchain = system: target: glibcHurd:
    let bp = (mkHurdCrossPkgs system target).buildPackages; in
    bp.wrapCCWith {
      cc       = finalGcc system target glibcHurd;
      libc     = glibcHurd;
      bintools = bp.wrapBintoolsWith {
        bintools = bp.binutils-unwrapped;
        libc     = glibcHurd;
      };
    };
in

{
  inherit finalGcc wrappedToolchain;

  # mkHurdBinutils : system -> name -> target -> derivation
  mkHurdBinutils = system: name: target:
    (mkHurdCrossPkgs system target).buildPackages.binutils-unwrapped;

  # mkHurdGccStage1 : system -> name -> target -> derivation
  mkHurdGccStage1 = system: name: target:
    (mkHurdCrossPkgs system target).buildPackages.gccWithoutTargetLibc;

  # Pre-libc components merged into packages.<system>: two outputs per
  # target (binutils + gcc-stage1).  glibc-hurd and the final gcc /
  # wrapped toolchain are merged separately from packages.nix.
  mkAll = system: targets:
    let
      hts = hurdTargets targets;
      pairs = lib.concatLists (lib.mapAttrsToList (name: target: [
        { name = "hurd-binutils-${name}";    value = (mkHurdCrossPkgs system target).buildPackages.binutils-unwrapped; }
        { name = "hurd-gcc-stage1-${name}";  value = (mkHurdCrossPkgs system target).buildPackages.gccWithoutTargetLibc; }
      ]) hts);
    in
    lib.listToAttrs pairs;

  # Post-libc components merged into packages.<system>: the final gcc +
  # wrapped toolchain per target.  `glibcHurd` is the attrset returned
  # by glibc.nix (keys `glibc-hurd-<name>`), threaded in from
  # packages.nix once glibc-hurd is built.
  mkFinal = system: targets: glibcHurd:
    let
      hts = hurdTargets targets;
      pairs = lib.concatLists (lib.mapAttrsToList (name: target:
        let g = glibcHurd."glibc-hurd-${name}"; in [
          { name = "hurd-gcc-${name}";       value = finalGcc system target g; }
          { name = "hurd-toolchain-${name}"; value = wrappedToolchain system target g; }
        ]) hts);
    in
    lib.listToAttrs pairs;
}
