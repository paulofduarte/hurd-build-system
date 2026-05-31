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
  #
  # libcCross is the REFERENCE glibc (Part 2 of the libc decoupling):
  # libgcc_s / libstdc++ are built against it once and stay valid against the
  # ABI-compatible working glibc (the POSIX wall — they don't encode the Mach
  # RPC ABI).  So gcc rebuilds only when the reference changes (a deliberate
  # *-ref-src bump), NOT when you hack the working glibc / headers / mig.
  finalGcc = system: target: refGlibc:
    (mkHurdCrossPkgs system target).buildPackages.gccWithoutTargetLibc.cc.override {
      withoutTargetLibc = false;
      langCC            = true;
      libcCross         = refGlibc;
      enableShared      = true;
    };

  # The wrapped cross-cc.  `cc` is the reference-built gcc; the cc-wrapper and
  # bintools-wrapper are pointed at the WORKING glibc (its headers / crt /
  # ld.so / augmented libc.so GROUP).  Re-pointing `working` is a wrapper
  # rebuild (seconds) — `wrapCCWith` never recompiles `cc`, so hacking the
  # working glibc doesn't rebuild gcc.  (Using the glibc-wrapped binutils
  # rather than the default cross binutils wrapper avoids dragging in nixpkgs'
  # own glibc, whose meta.platforms gate refuses the Hurd target at eval time.)
  wrappedToolchain = system: target: { reference, working }:
    let bp = (mkHurdCrossPkgs system target).buildPackages; in
    bp.wrapCCWith {
      cc       = finalGcc system target reference;
      libc     = working;
      bintools = bp.wrapBintoolsWith {
        bintools = bp.binutils-unwrapped;
        libc     = working;
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
  # wrapped toolchain per target.  `provider` is { reference; working; },
  # each the attrset glibc.nix returns (keys `glibc-hurd-<name>`): gcc's
  # libcCross binds the reference glibc, the wrapped cc points at the working
  # one.  Threaded in from packages.nix once both glibcs are built.
  mkFinal = system: targets: { reference, working }:
    let
      hts = hurdTargets targets;
      pairs = lib.concatLists (lib.mapAttrsToList (name: target:
        let
          refG  = reference."glibc-hurd-${name}";
          workG = working."glibc-hurd-${name}";
        in [
          { name = "hurd-gcc-${name}";       value = finalGcc system target refG; }
          { name = "hurd-toolchain-${name}"; value = wrappedToolchain system target { reference = refG; working = workG; }; }
        ]) hts);
    in
    lib.listToAttrs pairs;
}
