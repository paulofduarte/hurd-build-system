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

  # A complete cross-gcc: nixpkgs' own gcc builder with the target libc present
  # (withoutTargetLibc=false) so it builds libgcc_s + libstdc++, C++ enabled,
  # shared libs on.  Reusing the stage-1 cc's `.override` keeps every nixpkgs
  # gcc patch/phase; only the libc-facing knobs flip.
  #
  # `targetLibc` is the glibc libgcc_s / libstdc++ link against.  The 3-stage
  # bootstrap (PHASE-2-3STAGE-BOOTSTRAP.md) calls this twice:
  #   stage-2 gcc — targetLibc = the (throwaway) bootstrap glibc; the complete
  #                 seed compiler that then builds the reference glibc.
  #   final  gcc — targetLibc = the REFERENCE glibc; the userland cc, whose
  #                 libgcc_s/libstdc++ are the ABI-stable runtime (POSIX wall,
  #                 valid against the working glibc).  Rebuilds only on a
  #                 deliberate ref bump, never on a working-glibc hack.
  mkGcc = system: target: targetLibc:
    let
      bp  = (mkCrossPkgs system target).buildPackages;
      gcc = bp.gccWithoutTargetLibc.cc.override {
        withoutTargetLibc = false;
        langCC            = true;
        libcCross         = targetLibc;
        enableShared      = true;
      };
      # The per-target salt the cross bintools-wrapper suffixes its env vars
      # with (e.g. NIX_LDFLAGS_BEFORE_x86_64_gnu).  Derived from the target
      # config — `bp.stdenv` is the native build platform (salt
      # `_arm64_apple_darwin`), NOT the cross-targeting ld gcc's libgcc link
      # runs through, so its salt would be wrong.
      salt = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] target.crossTarget;
    in
    # The Hurd userland links only libgcc(_s) + libstdc++; the OpenMP runtime
    # is unused.  gcc 15's libgomp also fails to build against the Hurd glibc
    # headers — affinity-fmt.c trips -Werror=discarded-qualifiers — so building
    # it would only break the toolchain for a lib we never link.  nixpkgs only
    # passes --disable-libgomp on the withoutTargetLibc (stage-1) path; our
    # with-target-libc final gcc re-enables it, so append the flag back here.
    #
    # gcc builds libgcc_s/libstdc++ by linking `-lc` against the --prefix=/
    # reference glibc, whose libc.so is a GNU ld GROUP script with absolute
    # /lib members (GROUP ( /lib/libc.so.0.3 … )).  ld resolves those only with
    # an effective `--sysroot=${ref}`, but the nix ld-wrapper strips a
    # command-line `--sysroot` under sandbox purity — so gcc's own
    # `--with-sysroot`/SYSROOT_SPEC never reaches the raw ld.  This is the same
    # wall Phase 1 hit for the userland link; the same fix applies — mechanism
    # #2: feed the wrapper `--sysroot=${ref}` via NIX_LDFLAGS_BEFORE_<salt>,
    # which add-flags.sh keeps and the wrapper applies to the raw ld AFTER the
    # strip.  (The wrapper gcc's build links through is the cross-stdenv's, not
    # an instance we can wrap; the env var is the channel that reaches it.)
    #
    # patchelf: building libgcc_s/libstdc++ runs `patchelf --clear-execstack` on
    # each installed .so (the same glibc Makerules path), so without patchelf on
    # PATH the build logs "patchelf: command not found" per library.  Adding it
    # also registers patchelf's setup-hook (a `patchelf --shrink-rpath` fixup
    # pass) — which we don't want mutating the cross libs' RPATHs — so
    # dontPatchELF turns ONLY that shrink hook off, leaving the clear-execstack
    # call intact.  (Same pairing as glibc.nix.)  Unguarded — fine if it rebuilds.
    gcc.overrideAttrs (old: {
      configureFlags    = (old.configureFlags or []) ++ [ "--disable-libgomp" ];
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ bp.patchelf ];
      dontPatchELF      = true;
      env               = old.env // {
        # mechanism #2: `--sysroot` so the --prefix=/ targetLibc's /lib GROUP
        # resolves at the libgcc_s/libstdc++ link.  `-rpath /lib` bakes the
        # DEPLOYABLE RUNPATH (the target's own libc dir) instead of nixpkgs'
        # default `${targetLibc}/lib` (a /nix/store leak) — so the shipped
        # libgcc_s/libstdc++ need no dist `patchelf --remove-rpath`.  Both ride
        # NIX_LDFLAGS_BEFORE so they survive the ld-wrapper's purity strip (a
        # command-line `-rpath /lib` would be dropped as impure).
        "NIX_LDFLAGS_BEFORE${salt}" =
          (old.env."NIX_LDFLAGS_BEFORE${salt}" or "") + " --sysroot=${targetLibc} -rpath /lib";
        # Stop the wrapper auto-deriving -rpath from the -L dirs, and drop
        # nixpkgs' explicit store -rpath (keep -L + -rpath-link for build-time
        # resolution) — else `${targetLibc}/lib` would be baked alongside /lib.
        "NIX_DONT_SET_RPATH${salt}" = "1";
        EXTRA_LDFLAGS_FOR_TARGET = lib.replaceStrings
          [ " -Wl,-rpath,${targetLibc}/lib" ] [ "" ]
          (old.env.EXTRA_LDFLAGS_FOR_TARGET or "");
      };
    });

  # The wrapped cross-cc.  `cc` is the reference-built gcc; the cc-wrapper and
  # bintools-wrapper are pointed at the WORKING glibc (its headers / crt /
  # ld.so / augmented libc.so GROUP).  Re-pointing `working` is a wrapper
  # rebuild (seconds) — `wrapCCWith` never recompiles `cc`, so hacking the
  # working glibc doesn't rebuild gcc.  (Using the glibc-wrapped binutils
  # rather than the default cross binutils wrapper avoids dragging in nixpkgs'
  # own glibc, whose meta.platforms gate refuses the Hurd target at eval time.)
  wrappedToolchain = system: target: { cc, working }:
    let bp = (mkCrossPkgs system target).buildPackages; in
    bp.wrapCCWith {
      inherit cc;
      libc     = working;
      bintools = bp.wrapBintoolsWith {
        bintools = bp.binutils-unwrapped;
        libc     = working;
        # Mechanism #2 (load-bearing, in-sandbox-validated): inject --sysroot
        # via libc-ldflags-before -> NIX_LDFLAGS_BEFORE, applied by the ld-
        # wrapper AFTER its purity strip of command-line --sysroot, so the
        # working glibc's /lib-rooted libc.so GROUP resolves at link in nix
        # build sandboxes (where a CLI --sysroot is dropped).
        extraBuildCommands = ''
          echo "--sysroot=${working}" >> $out/nix-support/libc-ldflags-before
        '';
      };
    };
in

{
  inherit mkGcc wrappedToolchain hurdTargets;

  # Pre-libc components merged into packages.<system>: two outputs per
  # hurd target (binutils + gcc-stage1).  The 3-stage gcc/glibc chain
  # (bootstrap glibc -> stage-2 gcc -> ref glibc -> final gcc -> work glibc ->
  # wrapped toolchain) is orchestrated in packages.nix, since it interleaves
  # glibc.nix calls (which thread mig/headers) with `mkGcc`.
  mkAll = system: targets:
    let
      hts = hurdTargets targets;
      pairs = lib.concatLists (lib.mapAttrsToList (name: target: [
        { name = "cross-binutils-${name}";   value = (mkCrossPkgs system target).buildPackages.binutils-unwrapped; }
        { name = "cross-gcc-stage1-${name}"; value = (mkCrossPkgs system target).buildPackages.gccWithoutTargetLibc; }
      ]) hts);
    in
    lib.listToAttrs pairs;
}
