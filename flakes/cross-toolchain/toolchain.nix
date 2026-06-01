# Cross-toolchain components — per-target derivations, built against the
# patched `<cpu>-gnu` nixpkgs from pkgs.nix.
#
# Outputs (per non-xen userland target):
#   cross-binutils-<arch>     cross-binutils with target-prefixed
#                             binaries (`i686-gnu-as`, `i686-gnu-ld`, …).
#                             No libc dep; safe to build first.
#   cross-gcc-stage1-<arch>   gccWithoutTargetLibc — bare driver + cc1 +
#                             libgcc.a (no libgcc_s, no libstdc++, no
#                             libc dependency).  The libc-free cc that
#                             compiles gnumach-headers, mig, and glibc-hurd
#                             (gnumach's configure forces -ffreestanding
#                             -nostdlib, so the link test needs no libc).
#   cross-gcc-<arch>          final cross-gcc: C + C++, libgcc_s and
#                             libstdc++ linked against the REFERENCE
#                             glibc-hurd.  Same nixpkgs gcc builder as
#                             stage-1, flipped via withoutTargetLibc=false
#                             + libcCross.
#   toolchain-<arch>          THE toolchain: the wrapped cross-cc (cc-wrapper
#                             around the final gcc + the WORKING glibc-hurd +
#                             a glibc-hurd-wrapped binutils).  What the dev
#                             shell, the gnumach kernel, and the Hurd
#                             userland all build with, and what the cache
#                             workflow builds (`packages.<sys>.toolchain-<arch>`).
#
# `mkAll` emits the pre-libc components (binutils + stage-1).  The final
# gcc + wrapped toolchain need glibc-hurd, so `mkFinal` takes the
# reference/working glibc-hurd attrsets and is invoked from packages.nix
# after both glibcs are built.
#
# `hurdTargets` filters target-archs.nix to the non-xen userland targets —
# i686 and x86_64 today.  The xen variants share their CPU sibling's
# toolchain (same `<cpu>-gnu` ABI; the kernel links -nostdlib so the working
# glibc-hurd sysroot is irrelevant), so they are
# not duplicated here; packages.nix maps them onto the sibling toolchain.

{ nixpkgs, mkCrossPkgs }:

let
  lib = nixpkgs.lib;

  hurdTargets = targets:
    lib.filterAttrs (name: target: (target.platform or null) != "xen") targets;

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
    let
      gcc = (mkCrossPkgs system target).buildPackages.gccWithoutTargetLibc.cc.override {
        withoutTargetLibc = false;
        langCC            = true;
        libcCross         = refGlibc;
        enableShared      = true;
      };
    in
    # The Hurd userland links only libgcc(_s) + libstdc++; the OpenMP runtime
    # is unused.  gcc 15's libgomp also fails to build against the Hurd glibc
    # headers — affinity-fmt.c trips -Werror=discarded-qualifiers — so building
    # it would only break the toolchain for a lib we never link.  nixpkgs only
    # passes --disable-libgomp on the withoutTargetLibc (stage-1) path; our
    # with-target-libc final gcc re-enables it, so append the flag back here.
    # The builder computes configureFlags internally (no override arg), hence
    # overrideAttrs rather than a builder parameter.
    gcc.overrideAttrs (old: {
      configureFlags = (old.configureFlags or []) ++ [ "--disable-libgomp" ];
    });

  # The wrapped cross-cc.  `cc` is the reference-built gcc; the cc-wrapper and
  # bintools-wrapper are pointed at the WORKING glibc (its headers / crt /
  # ld.so / augmented libc.so GROUP).  Re-pointing `working` is a wrapper
  # rebuild (seconds) — `wrapCCWith` never recompiles `cc`, so hacking the
  # working glibc doesn't rebuild gcc.  (Using the glibc-wrapped binutils
  # rather than the default cross binutils wrapper avoids dragging in nixpkgs'
  # own glibc, whose meta.platforms gate refuses the Hurd target at eval time.)
  wrappedToolchain = system: target: { reference, working }:
    let bp = (mkCrossPkgs system target).buildPackages; in
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
  inherit finalGcc wrappedToolchain hurdTargets;

  # Pre-libc components merged into packages.<system>: two outputs per
  # hurd target (binutils + gcc-stage1).  glibc-hurd and the final gcc /
  # wrapped toolchain are merged separately from packages.nix.
  mkAll = system: targets:
    let
      hts = hurdTargets targets;
      pairs = lib.concatLists (lib.mapAttrsToList (name: target: [
        { name = "cross-binutils-${name}";   value = (mkCrossPkgs system target).buildPackages.binutils-unwrapped; }
        { name = "cross-gcc-stage1-${name}"; value = (mkCrossPkgs system target).buildPackages.gccWithoutTargetLibc; }
      ]) hts);
    in
    lib.listToAttrs pairs;

  # Post-libc components merged into packages.<system>: the final gcc +
  # the wrapped toolchain per hurd target.  `provider` is
  # { reference; working; }, each the attrset glibc.nix returns (keys
  # `glibc-hurd-<name>`): gcc's libcCross binds the reference glibc, the
  # wrapped cc points at the working one.  Threaded in from packages.nix
  # once both glibcs are built.
  mkFinal = system: targets: { reference, working }:
    let
      hts = hurdTargets targets;
      pairs = lib.concatLists (lib.mapAttrsToList (name: target:
        let
          refG  = reference."glibc-hurd-${name}";
          workG = working."glibc-hurd-${name}";
        in [
          { name = "cross-gcc-${name}"; value = finalGcc system target refG; }
          { name = "toolchain-${name}"; value = wrappedToolchain system target { reference = refG; working = workG; }; }
        ]) hts);
    in
    lib.listToAttrs pairs;
}
