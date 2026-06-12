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
  # Stable names for a wrapped toolchain's three store paths.  `toolchain` is a
  # `wrapCCWith` result: `.cc` is the underlying gcc (whose include dirs leak),
  # `.bintools` the wrapped binutils.
  debugPrefixMap = toolchain: [
    "-fdebug-prefix-map=${toolchain}=/cross-cc-wrapper"
    "-fdebug-prefix-map=${toolchain.cc}=/cross-gcc"
    "-fdebug-prefix-map=${toolchain.bintools}=/cross-binutils-wrapper"
  ];

  debugPrefixMapStr = toolchain: lib.concatStringsSep " " (debugPrefixMap toolchain);

  # Fixed cross-build random seed, replacing the host-varying one the
  # reproducible-builds hook derives from $out.
  randomSeed = "gnu-hurd-cross";

  # Derivation attrs every cross build shares: parallel make, and keep the -g DWARF
  # (the ABI gate / debugging need it).  Spread with `// commonAttrs`.
  commonAttrs = {
    enableParallelBuilding = true;
    dontStrip = true;
  };

  # Global compile flags - the SINGLE source of truth for every non-toolchain,
  # non-deliverable-glibc cross build: gnumach, hurd, mig, the *-headers, AND the
  # cross-gcc TARGET runtime libs (libgcc/libstdc++, via CFLAGS_FOR_TARGET - NOT the
  # gcc compiler proper).  The deliverable glibc sets its own.  Consumed by the nix
  # derivations and, via the dev-shell BASE_CFLAGS export, the in-tree Makefile.
  baseCflags = "-g -O2";
  # hurd predates gcc's -fno-common default (gcc 10+); it alone prepends -fcommon.
  hurdExtraCflags = "-fcommon";

  # Strip host build-tool `-isystem /nix/store/*` (+ their macro-prefix-maps) AND the
  # hook's $out-derived -frandom-seed from NIX_CFLAGS_COMPILE: a cross-compile must
  # resolve system headers from its own sysroot only (on darwin mkShell leaks e.g. the
  # host libiconv ahead of the target glibc).  Shared by dev-shell.nix and the hurd
  # derivation's preBuild (sed -E program; sedSeedOnly drops just the seed).
  sedSeedOnly     = "s/-frandom-seed=[^ ]*//g";
  isystemStripSed = "${sedSeedOnly}; s#-isystem +/nix/store/[^ ]*##g; s#-fmacro-prefix-map=/nix/store/[^ ]*##g";

  # The preBuild NIX_CFLAGS_COMPILE rewrite for an OUT-OF-TREE cross build: strip the
  # hook's seed (+ optionally host -isystem leaks), add the toolchain debug-prefix-map,
  # map the absolute srcdir AND build dir to one canonical root, then pin the seed.
  # `$srcdir` from the out-of-tree preConfigure; `$PWD` is the build dir.  Returns the
  # `export ...` line; consumers (gnumach/hurd preBuild) compose around it.
  detCflagsExport = { toolchain, canonBuild, stripIsystem ? false }:
    ''export NIX_CFLAGS_COMPILE="$(printf %s "$NIX_CFLAGS_COMPILE" | sed -E '${if stripIsystem then isystemStripSed else sedSeedOnly}') ${debugPrefixMapStr toolchain} -ffile-prefix-map=$srcdir=${canonBuild} -ffile-prefix-map=$PWD=${canonBuild} -frandom-seed=${randomSeed}"'';

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
  glibcCanonSrc     = "/glibc-src";
  glibcCanonBuild   = "/glibc-build";
  glibcCanonSysroot = "/glibc-sysroot";

  # One canonical root per gnumach/hurd build, so their nix builds come out
  # byte-identical to the in-tree Makefile builds.  The nix builds run IN-SOURCE
  # (one $PWD = src+build); the in-tree builds run out-of-tree (separate dirs).
  # Mapping ALL to a SINGLE name reconciles the two layouts (identical relative
  # paths under one root).  Consumed by gnumach/hurd default.nix + the Makefile.
  gnumachCanonBuild = "/gnumach-build";
  hurdCanonBuild    = "/hurd-build";

  # cross-gcc-runtime: one canon root pair so its target libs come out cross-host
  # reproducible (the gcc build dir + source are host-varying sandbox/store paths).
  gccRuntimeCanonSrc     = "/gcc-runtime-src";
  gccRuntimeCanonBuild   = "/gcc-runtime-build";
  gccRuntimeCanonSysroot = "/gcc-runtime-sysroot";

  # Canonical name for the split rt-libgcc package the wrapper -B's: gcc's
  # internal include dir lives inside it, and DWARF .debug_line_str records
  # that dir on any TU touching a gcc-internal header (libstdc++exp.a, libitm).
  # Without the map those bytes shift whenever libgcc's STORE PATH moves, even
  # content-identical rebuilds.  Consumed by toolchain.nix's wrapper.
  libgccCanonRoot = "/libgcc";
}
