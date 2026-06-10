# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-toolchain components - per-target derivations, built against the
# patched `<cpu>-gnu` nixpkgs from pkgs.nix.
#
# Outputs (per non-xen userland target):
#   cross-binutils-<arch>     cross-binutils, target-prefixed (`i686-gnu-as`, ...).
#                             No libc dep; safe to build first.
#   cross-gcc-stage1-<arch>   bootstrap-gcc (gccWithoutTargetLibc) - bare driver +
#                             cc1 + libgcc.a (no libgcc_s/libstdc++/libc).  The
#                             libc-free cc that compiles gnumach-headers, mig, and
#                             the REFERENCE glibc (gnumach's configure forces
#                             -ffreestanding -nostdlib, so its link test needs no libc).
#   toolchain-<arch>          THE toolchain: the wrapped cross-cc (cross-gcc + the
#                             WORKING glibc-hurd + a glibc-hurd-wrapped binutils,
#                             -B'd to the work-built libgcc).  What the dev shell,
#                             gnumach, and the Hurd userland build with, and what
#                             the cache workflow builds.
#
# (cross-gcc itself + the split runtime libs live in gcc-runtime.nix; packages.nix
# orchestrates the chain after the glibcs are built.)
#
# `hurdTargets` filters target-archs.nix to the non-xen userland targets
# (i686, x86_64).  The xen variants share their CPU sibling's toolchain (same
# `<cpu>-gnu` ABI; the kernel links -nostdlib so the working glibc-hurd sysroot
# is irrelevant), so packages.nix maps them onto the sibling toolchain.

{ nixpkgs, mkCrossPkgs }:

let
  lib = nixpkgs.lib;
  buildFlags = import ./build-flags.nix { inherit lib; };

  hurdTargets = targets:
    lib.filterAttrs (name: target: (target.platform or null) != "xen") targets;

  # The wrapped cross-cc.  `cc` is cross-gcc (ref-bound, posix, no runtime); the
  # cc-wrapper and bintools-wrapper point at the WORKING glibc (headers / crt /
  # ld.so / augmented libc.so GROUP).  Re-pointing `working` is a wrapper rebuild (seconds) -
  # wrapCCWith never recompiles `cc`, so hacking the working glibc doesn't rebuild
  # gcc.  We wrap binutils-unwrapped rather than the default cross binutils wrapper
  # to avoid dragging in nixpkgs' own glibc, whose meta.platforms gate refuses the
  # Hurd target at eval time.
  # libgcc (optional): a derivation providing the WORK-built libgcc/crt under
  # lib/gcc/<tgt>/<ver>/ (cross-gcc-runtime / the split libgcc).  When set, every link
  # through this toolchain uses it instead of cc's own REF-built copy - the runtime is
  # actually consumed + ABI-consistent with the working glibc.  Omitted for the wrapped
  # cc that BUILDS the runtime (no self-dependency).
  wrappedToolchain = system: target: { cc, working, libgcc ? null }:
    let
      bp   = (mkCrossPkgs system target).buildPackages;
      salt = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] target.crossTarget;
    in
    bp.wrapCCWith {
      inherit cc;
      libc     = working;
      # The FLIP: cross-gcc bakes the pinned REFERENCE glibc as its native sys-include
      # (its libcCross), and the wrapper's own libc headers land at -idirafter (after it),
      # so ref would win.  Add the WORKING glibc headers at -isystem (ahead of the gcc
      # sys-include) so user code AND the runtime libs compile against WORKING - everything
      # converges on the work ABI, so no ref-vs-work ABI gate is needed.  working/include
      # carries the merged glibc + mach + hurd tree, so this is the whole system surface.
      extraBuildCommands = ''
        echo "-isystem ${working}/include" >> $out/nix-support/cc-cflags
      '' + lib.optionalString (libgcc != null) ''
        # Link the WORK-built libgcc.a/libgcc_eh.a/libgcc_s/crt*.o (against the working
        # glibc) instead of cc's REF-built copies: -B puts the runtime's lib/gcc/<tgt>/<ver>
        # ahead of the compiler's (-lgcc/-lgcc_eh + startfiles), and -L its lib/ so -lgcc_s
        # resolves there too.  libgcc.a is NOT uniformly ABI-neutral (the unwinder/__emutls/
        # header-using objects bake glibc/Mach types), so this is load-bearing, not cosmetic.
        echo "-B${libgcc}/lib/gcc/${target.crossTarget}/${cc.version}" >> $out/nix-support/cc-cflags
        echo "-L${libgcc}/lib" >> $out/nix-support/cc-ldflags
      '';
      bintools = bp.wrapBintoolsWith {
        bintools = bp.binutils-unwrapped;
        libc     = working;
        # No --sysroot.  How the deployable glibc's libc.so GROUP ld-script resolves
        # at link depends on which `working` we wrap:
        #  - The bare-name re-export farm (bareGlibcHurd in packages.nix) the userland
        #    toolchain links against rewrites the GROUP to BARE NAMES (libc.so.0.3,
        #    libmachuser.so, ...).  ld resolves them via the -L"${working}/lib" the
        #    wrapper already adds - no --sysroot, never doubled, host-uniform.
        #  - A RAW deployable glibc used as a glibc buildCC's prior libc keeps its
        #    /lib GROUP, but the nix ld-wrapper strips a CLI --sysroot under purity
        #    (so it never reached ld in a Linux sandbox anyway), and the glibc build's
        #    configure link tests don't bind the prior libc's full GROUP, so they pass
        #    without it.  On darwin --sysroot WAS honoured and doubled an already-
        #    absolute GROUP member ("cannot find ... inside ...").  So bare names need no
        #    sysroot at all.
        #
        # NIX_DONT_SET_RPATH: stop the ld-wrapper auto-baking a /nix/store rpath to
        # working/lib on anything linked through this wrapper; glibc's slibdir=/lib +
        # SONAME NEEDED resolve via the target /lib.  (DRY: in the wrapper, not a
        # per-build export in glibc.nix.)
        extraBuildCommands = ''
          echo "export NIX_DONT_SET_RPATH${salt}=1" >> $out/nix-support/add-local-ldflags-before.sh
        '';
      };
    };
in

{
  inherit wrappedToolchain hurdTargets;

  # Pre-libc components merged into packages.<system>: two outputs per hurd
  # target (binutils + gcc-stage1).  The toolchain chain (bootstrap-gcc -> ref
  # glibc -> cross-gcc -> work glibc -> cross-gcc-rt-* + wrapped toolchain) is
  # orchestrated in packages.nix, since it interleaves glibc.nix calls (which
  # thread mig/headers) with gcc-runtime.nix's mkCompiler/mkRuntimeLib.
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
