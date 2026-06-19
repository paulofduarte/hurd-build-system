# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared determinism build flags for the cross builds - consumed by the nix
# kernel/userland builds (flakes/gnumach, flakes/hurd) AND the in-tree dev
# shell (dev-shell.nix), so gnumach/hurd/glibc come out byte-identical on
# every host.  Two host-varying inputs otherwise leak into the output:
#
#   1. The cross-toolchain's own /nix/store paths (gcc's internal include /
#      sys-include dirs) recorded in DWARF - the store hash is per-host, so the
#      same source yields different DWARF.  `debugPrefixMap` rewrites each to a
#      stable name (values arbitrary; only stability matters, paths stay usable).
#
#   2. gcc's `-frandom-seed`, which nixpkgs' reproducible-builds setup hook
#      derives from $out (host-varying here).  It feeds gcc's symbol-name
#      uniquifier, perturbing .text/.rodata of seed-sensitive TUs (all of glibc
#      + the hurd servers).  Pin it to `randomSeed`.  No runtime-security impact:
#      compile-time symbol naming only, not runtime entropy (canary/ASLR/RELRO/
#      PIE are independent).

{ lib }:

rec {
  # The from-source builds invoke the cc UNWRAPPED (a plain gcc derivation - no
  # wrapCCWith `.cc`/`.bintools`).  gcc's internal include dir lives inside the gcc
  # store path and leaks into DWARF, so map the gcc + binutils store paths to stable
  # names.  Fed into the build's own CPPFLAGS (no wrapper to inject
  # NIX_CFLAGS_COMPILE).  Used by the from-source glibc / full gcc / hurd-stubs and
  # the gnumach/hurd/dev-shell determinism maps.
  debugPrefixMapUnwrapped = { gcc, binutils }: [
    "-fdebug-prefix-map=${gcc}=/cross-gcc"
    "-fdebug-prefix-map=${binutils}=/cross-binutils"
  ];
  debugPrefixMapUnwrappedStr = args: lib.concatStringsSep " " (debugPrefixMapUnwrapped args);

  # Derivation attrs every cross build shares.  Spread with `// commonAttrs`.
  #   enableParallelBuilding : parallel make.
  #   dontStrip              : keep the -g DWARF (the ABI gate / debugging need it).
  #   dontPatchELF           : never run nixpkgs' fixup patchelf hook.  The hook
  #     (--shrink-rpath / exec-stack) exists only on Linux, so letting it touch the
  #     TARGET ELFs (libgcc + the shipped runtime libs) would make them diverge
  #     cross-host - and it has nothing to do anyway, since the unwrapped cross ld
  #     bakes no /nix/store rpath to shrink.  (glibc/gnumach/hurd/mig don't spread
  #     commonAttrs - they set their own dontPatchELF inline.)
  commonAttrs = {
    enableParallelBuilding = true;
    dontStrip = true;
    dontPatchELF = true;
  };

  # Build tools every toolchain component needs on PATH - distinct from the fixup
  # shrink hook that dontPatchELF (above) disables.  patchelf: the vanilla builds
  # invoke it THEMSELVES (glibc's Makerules `--clear-execstack`; gcc), so the binary
  # must be present even though we suppress nixpkgs' post-build patchelf fixup.
  # (Pulling patchelf in also registers its --shrink-rpath setup-hook; dontPatchELF
  # guards exactly that, so the two compose.)  A function of pkgs since build-flags
  # only receives lib - pass the right set (buildPackages for cross derivations):
  #   nativeBuildInputs = [ ... ] ++ commonNativeBuildInputs pkgs;
  #
  # patchelfUnstable (>= 0.18.0), NOT the default `patchelf`: nixpkgs pins the
  # plain `patchelf` low (0.15.2) for the stdenv bootstrap, but glibc's Makerules
  # gate the `--clear-execstack` scrub on patchelf >= 0.18.0 - so the older one
  # silences glibc's probe yet skips the actual scrub.  Using the >= 0.18.0 build
  # makes the scrub run (uniformly, since the pin fixes its rev), so the exec-stack
  # flags are cleared the same way on every host.
  commonNativeBuildInputs = pkgs: [ pkgs.patchelfUnstable ];

  # Global compile flags - the SINGLE source of truth for every non-toolchain,
  # non-deliverable-glibc cross build: gnumach, hurd, mig, the *-headers, AND the
  # cross-gcc TARGET runtime libs (libgcc/libstdc++, via CFLAGS_FOR_TARGET - NOT the
  # gcc compiler proper).  The deliverable glibc sets its own.  Consumed by the nix
  # derivations and, via the dev-shell BASE_CFLAGS export, the in-tree Makefile.
  baseCflags = "-g -O2";
  # hurd predates gcc's -fno-common default (gcc 10+); it alone prepends -fcommon.
  hurdExtraCflags = "-fcommon";

  # The OUT-OF-TREE determinism map export for the from-source toolchain:
  # gnumach/hurd's cross-cc is the raw cross-gcc, which ignores the cc-wrapper's
  # NIX_CFLAGS_COMPILE - so the determinism maps go through the build's own CPPFLAGS
  # (applied to every .c AND .S compile, the same universal channel the glibc fix
  # uses).  Maps the raw gcc + binutils store paths (debugPrefixMapUnwrapped) and the
  # out-of-tree $srcdir + $PWD (build dir) to one canon root.  No -frandom-seed (the
  # raw cc never sees the hook's $out seed; its default seed is output-name-derived =
  # deterministic).  Returns the `export CPPFLAGS=...` line; call from preConfigure
  # AFTER outOfTreePreConfigure (which sets $srcdir), so configure bakes it.
  # `sysroot` (optional): the glibc-hurd the cross-gcc is bound to.  A consumer that
  # INCLUDES glibc headers (the hurd userland) leaks that IA, host-varying sysroot path
  # into its DWARF, so map it to ${glibcCanonSysroot}.  Freestanding consumers (the
  # -nostdlib kernel) pull no glibc headers and pass no sysroot (no-op).
  detCppflagsUnwrapped =
    {
      gcc,
      binutils,
      canonBuild,
      sysroot ? null,
    }:
    ''export CPPFLAGS="${debugPrefixMapUnwrappedStr { inherit gcc binutils; }}${
      lib.optionalString (sysroot != null) " -ffile-prefix-map=${sysroot}=${glibcCanonSysroot}"
    } -ffile-prefix-map=$srcdir=${canonBuild} -ffile-prefix-map=$PWD=${canonBuild} ''${CPPFLAGS:-}"'';

  # Canonical replacement roots for glibc's own paths, so the glibc build is
  # reproducible cross-host AND byte-identical whether built in-tree or via nix.
  # The real roots differ per method and some are host-VARYING:
  #   source : in-tree $(GLIBC_SRC) /Volumes/.../src/glibc | nix $src /nix/store/-source
  #   build  : in-tree $(GLIBC_BUILDDIR)                    | nix the SANDBOX build dir
  #   sysroot: in-tree $(SYSROOT)                           | nix $TMPDIR/sysroot
  # The nix build/sysroot live in the sandbox temp, host-varying (linux /build vs
  # darwin /builds/nix-<pid>-<rand>) - so without these maps the nix glibc diverges
  # cross-host even with the gcc map.  Each build -ffile-prefix-map's its real roots
  # to these names; consumed by glibc.nix and the in-tree Makefile (dev-shell env).
  glibcCanonSrc = "/glibc-src";
  glibcCanonBuild = "/glibc-build";
  glibcCanonSysroot = "/glibc-sysroot";

  # One canonical root per gnumach/hurd build, so their nix builds come out
  # byte-identical to the in-tree Makefile builds.  The nix builds run IN-SOURCE
  # (one $PWD = src+build); the in-tree builds run out-of-tree (separate dirs).
  # Mapping ALL to a SINGLE name reconciles the two layouts (identical relative
  # paths under one root).  Consumed by gnumach/hurd default.nix + the Makefile.
  gnumachCanonBuild = "/gnumach-build";
  hurdCanonBuild = "/hurd-build";

  # Canonical replacement for the from-source gcc BUILD SANDBOX root ($NIX_BUILD_TOP).
  # gcc unpacks its source + builds under there, and libgcc's DWARF bakes those paths
  # in.  The sandbox root is FIXED as /build on linux but PER-BUILD
  # (/nix/var/nix/builds/nix-<pid>-<rand>) on darwin - so without this map two darwin
  # builds of the bootstrap gcc yield different libgcc, and any glibc/binary that
  # statically links libgcc (libc.so, libm.so, sln) diverges cross-host.  Mapping
  # $NIX_BUILD_TOP -> this constant (covers source/ + build/ under it) makes libgcc's
  # DWARF identical on every host.  Fed via CFLAGS_FOR_TARGET in gcc.nix.
  gccCanonRoot = "/gcc";
}
