# Shared determinism build flags for the cross builds — consumed by the nix
# kernel/userland builds (flakes/gnumach, flakes/hurd) AND the in-tree dev
# shell (dev-shell.nix), so gnumach/hurd/glibc come out byte-identical on
# every host.  Two host-varying inputs otherwise leak into the output:
#
#   1. The cross-toolchain's own /nix/store paths — gcc's internal `include`
#      and `sys-include` dirs — recorded in DWARF (.debug_str/.debug_line_str,
#      and referenced from .debug_info).  The store hash differs per host
#      (nix input-addresses the cross-gcc per build platform), so the same
#      source yields different DWARF on each host.  `debugPrefixMap` rewrites
#      each toolchain path to a stable name; the values are arbitrary, only
#      their stability matters, and debug info stays usable (paths only).
#
#   2. gcc's `-frandom-seed`, which nixpkgs' reproducible-builds setup hook
#      (pkgs/build-support/setup-hooks/reproducible-builds.sh) derives from
#      $out — host-varying for our cross derivations and the dev shell, since
#      the toolchain input's store hash differs per host.  The seed feeds
#      gcc's symbol-name uniquifier, perturbing .text/.rodata of seed-sensitive
#      TUs (all of glibc + the hurd servers).  Pin it to `randomSeed`.  No
#      runtime-security impact: it is compile-time symbol naming only, not
#      runtime entropy (stack canary, ASLR, RELRO/PIE are all independent).

{ lib }:

rec {
  # Stable names for a wrapped toolchain's three store paths.  `toolchain` is
  # a `wrapCCWith` result, so `.cc` is the underlying gcc (the one whose
  # include dirs leak) and `.bintools` the wrapped binutils.
  debugPrefixMap = toolchain: [
    "-fdebug-prefix-map=${toolchain}=/cross-cc-wrapper"
    "-fdebug-prefix-map=${toolchain.cc}=/cross-gcc"
    "-fdebug-prefix-map=${toolchain.bintools}=/cross-binutils-wrapper"
  ];

  debugPrefixMapStr = toolchain: lib.concatStringsSep " " (debugPrefixMap toolchain);

  # Fixed cross-build random seed, replacing the host-varying one the
  # reproducible-builds hook derives from $out.
  randomSeed = "gnu-hurd-cross";

  # Global compile flags — the SINGLE source of truth for every non-toolchain,
  # non-deliverable-glibc cross build: gnumach, hurd, mig, the *-headers, AND the
  # cross-gcc TARGET runtime libs (libgcc/libstdc++, via CFLAGS_FOR_TARGET — NOT the
  # gcc compiler proper).  The deliverable glibc sets its own.  Consumed by the nix
  # derivations and, via the dev-shell BASE_CFLAGS export, the in-tree Makefile.
  baseCflags = "-g -O2";
  # hurd predates gcc's -fno-common default (gcc 10+); it alone prepends -fcommon.
  hurdExtraCflags = "-fcommon";

  # Strip host build-tool `-isystem /nix/store/*` (+ their macro-prefix-maps) AND the
  # reproducible-builds hook's $out-derived -frandom-seed from NIX_CFLAGS_COMPILE: a
  # cross-compile must resolve system headers from its own sysroot only (on darwin the
  # native stdenv / mkShell dumps every nativeBuildInput's include, leaking e.g. the
  # host libiconv ahead of the target glibc).  Shared by dev-shell.nix and the hurd
  # derivation's preBuild (sed -E program; sedSeedOnly drops just the seed).
  sedSeedOnly     = "s/-frandom-seed=[^ ]*//g";
  isystemStripSed = "${sedSeedOnly}; s#-isystem +/nix/store/[^ ]*##g; s#-fmacro-prefix-map=/nix/store/[^ ]*##g";

  # The preBuild NIX_CFLAGS_COMPILE rewrite for an OUT-OF-TREE cross build: strip the
  # hook's seed (+ optionally host -isystem leaks), add the toolchain debug-prefix-map,
  # map the absolute srcdir AND build dir to one canonical root, then pin the seed.
  # `$srcdir` is exported by the out-of-tree preConfigure; `$PWD` is the build dir.
  # Returns the `export …` line; consumers (gnumach/hurd preBuild) compose around it.
  detCflagsExport = { toolchain, canonBuild, stripIsystem ? false }:
    ''export NIX_CFLAGS_COMPILE="$(printf %s "$NIX_CFLAGS_COMPILE" | sed -E '${if stripIsystem then isystemStripSed else sedSeedOnly}') ${debugPrefixMapStr toolchain} -ffile-prefix-map=$srcdir=${canonBuild} -ffile-prefix-map=$PWD=${canonBuild} -frandom-seed=${randomSeed}"'';

  # Canonical replacement roots for glibc's own paths, so the glibc build is
  # reproducible cross-host AND byte-identical whether built in-tree or via nix.
  # The real roots differ per method and some are host-VARYING:
  #   source : in-tree $(GLIBC_SRC) /Volumes/.../src/glibc | nix $src /nix/store/-source
  #   build  : in-tree $(GLIBC_BUILDDIR)                    | nix the SANDBOX build dir
  #   sysroot: in-tree $(SYSROOT)                           | nix $TMPDIR/sysroot
  # The nix build/sysroot live in the sandbox temp ($NIX_BUILD_TOP/$TMPDIR), which
  # varies per host (linux /build vs darwin /builds/nix-<pid>-<rand>) — so without
  # these maps the nix glibc diverges cross-host even with the gcc map.  Each build
  # -ffile-prefix-map's its real roots to these names; consumed by glibc.nix (nix
  # side) and the in-tree Makefile (via the dev-shell env — see dev-shell.nix).
  glibcCanonSrc     = "/glibc-src";
  glibcCanonBuild   = "/glibc-build";
  glibcCanonSysroot = "/glibc-sysroot";

  # One canonical root per gnumach/hurd build, so their nix builds (flakes/gnumach,
  # flakes/hurd) come out byte-identical to the in-tree Makefile builds.  The nix
  # builds run IN-SOURCE (one $PWD = src+build); the in-tree builds run out-of-tree
  # (separate src + build dirs).  Mapping ALL of them to a SINGLE name reconciles
  # the two layouts (identical relative paths under one root).  Consumed by
  # gnumach/default.nix + hurd/default.nix and the in-tree Makefile (dev-shell env).
  gnumachCanonBuild = "/gnumach-build";
  hurdCanonBuild    = "/hurd-build";
}
