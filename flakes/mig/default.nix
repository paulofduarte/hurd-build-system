# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# GNU MIG - per-target cross-compiler derivations (autoreconf + configure +
# make + make install), producing the per-target MIG binary + migcom under
# $out/{bin,libexec}.
#
# Two build modes, selected by the optional `checkToolchains` arg:
#
#   BOOTSTRAP (checkToolchains == null) - `mig-<name>`, built with the libc-free
#     stage-1 cross cc, `doCheck = false`.  This is the mig that builds the
#     toolchain itself (hurd-headers, glibc-hurd), so it MUST precede any libc
#     and can't run its tests (they compile stubs that #include <string.h>, a
#     hosted-libc header the nolibc cc lacks).
#
#   CHECKED (checkToolchains = the wrapped-cc attrset) - built with the wrapped
#     cc (toolchain-<name>), whose glibc-hurd sysroot provides <string.h>, so
#     `doCheck = true` can compile the test stubs.  migcom is native-host-cc and
#     cpu.h an -ffreestanding TARGET_CC compile in BOTH modes, so the installed
#     bytes are identical to the bootstrap mig - a byte-identical revalidation
#     that the mig which built glibc is sound, not a different artifact.  It sits
#     downstream of glibc-hurd; packages.nix wires it in after the final
#     toolchain (no cycle) and routes glibc's consumers at it.
#
# `doCheck` runs MIG's own `make check` (good/, bad/, generate-only/) in the
# sandbox.  The test_lib.sh harness uses `$CC -E -x c` for cpp, so preprocessing
# is target-aware.
#
# Per-target attrset fields (see target-archs.nix + flake.nix):
#   crossTarget : nixpkgs cross-system config (`<cpu>-gnu`) - drives TARGET_CC
#                 (cpu.symc + test stubs), ./configure --target=, and the binary
#                 name (<crossTarget>-mig + <crossTarget>-migcom).
#   platform    : unused by MIG (a gnumach-side concern).
#
# Source comes from the pinned `mig-src` flake input, NOT the local src/mig clone.
#
# `gnumachHeaders` is the attrset from flakes/gnumach-headers; "gnumach-headers-
# <name>" gives cpu.sym its <mach/message.h>.  TARGET_CPPFLAGS points at
# $gnumach-headers/include.

{ nixpkgs, system, targets, gnumachHeaders, mkCrossPkgs, srcInput, forkUrl
, checkToolchains ? null }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  # CHECKED pass when a wrapped-cc attrset is threaded in (built downstream
  # of glibc-hurd in packages.nix); BOOTSTRAP pass otherwise.
  checked = checkToolchains != null;

  # Upstream version parsed from configure.ac (AC_INIT line).
  upstreamVersion = helpers.parseAcInitVersion (srcInput + "/configure.ac");

  # PACKAGE_VERSION composed at eval time.
  fullVersion = helpers.composeToolchainVersion {
    inherit upstreamVersion srcInput forkUrl;
  };

  mkOne = name: target:
    let
      gnumach-headers = gnumachHeaders."gnumach-headers-${name}";
      crossPkgs = mkCrossPkgs system target;
      # BOOTSTRAP: the libc-free stage-1 cc (gccWithoutTargetLibc) - the
      # `<cpu>-gnu` cross stdenv's own `.cc` would pull nixpkgs' meta-gated glibc
      # and break eval.  CHECKED: the wrapped cc, whose glibc-hurd sysroot gives
      # the test stubs their <string.h>.  Both share the same `<cpu>-gnu-`
      # targetPrefix and compile cpu.symc identically (-ffreestanding), so the
      # installed bytes match.
      cc = if checked then checkToolchains."toolchain-${name}"
           else crossPkgs.buildPackages.gccWithoutTargetLibc;
      toolPrefix = cc.targetPrefix;
      pname = "mig-${target.crossTarget}";
    in
    # Native stdenv: MIG itself is a host tool.  Cross tools come in via
    # nativeBuildInputs + explicit env vars below.
    pkgs.stdenv.mkDerivation ({
      inherit pname;

      # Drives the store path suffix and (via the sed below) the binary's
      # PACKAGE_VERSION.
      version = fullVersion;

      # The locked flake input, never the local src/mig clone, so the built bytes
      # match the rev the version string advertises (use `make mig` for iterative
      # dev - that path bypasses nix).
      src = srcInput;

      # Cross-build fixes that landed upstream after the v1.8+git20231217 release
      # tag but before our baseline, needed to build the older reference mig:
      #   00  accept a TARGET_CC whose name isn't <target>-gcc (we supply
      #       i686-unknown-none-elf-gcc) - else configure aborts "could not find
      #       a compiler".
      #   01  test harness honours external CFLAGS (our gnumach-headers -I).
      #   02  test harness preprocesses .defs with the target compiler.
      #   03  GCC-14 compat: declare the mig_*_reply_port prototypes + pull
      #       <string.h> into the test's mig_support.h (modern compilers reject
      #       the implicit declarations the 2023 fixtures relied on).
      # All four are in current pins, so this is a no-op for the working source;
      # it only fires for an older mig-src rev.  Guarded by the input's commit date.
      patches = lib.optionals
        (builtins.substring 0 8 (srcInput.lastModifiedDate or "00000000") < "20260524")
        [ ./patches/00-accept-non-canonical-cross-compilers.patch
          ./patches/01-tests-honour-external-cflags.patch
          ./patches/02-tests-preprocess-defs-target-compiler.patch
          ./patches/03-tests-gcc14-compat.patch
        ];

      # autoreconfHook supplies autoconf/automake/libtool/m4.  bison/flex are
      # MIG's own needs (parser.y + lexxer.l).  The cross cc is for TARGET_CC
      # (cpu.symc) + the test stubs.  patchelf: matches the other derivations so
      # the stdenv audit-tmpdir fixup can run - on a Linux builder migcom is an
      # ELF and the audit runs (shrink hook would fire - see dontPatchELF); on
      # darwin migcom is Mach-O and patchelf is a no-op.  Carried unconditionally
      # for uniform behaviour across hosts.
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ bison flex patchelf ])
        ++ [ cc ];

      CFLAGS = buildFlags.baseCflags;

      # Splice the composed version into AC_INIT before autoreconfHook
      # regenerates configure.
      postPatch = ''
        sed -i.bak \
          -e 's|^AC_INIT(\[GNU MIG\], \[[^]]*\],|AC_INIT([GNU MIG], [${fullVersion}],|' \
          configure.ac
        rm configure.ac.bak
        grep "^AC_INIT" configure.ac
      '';

      # MIG's cpu.symc is compiled by TARGET_CC; the resulting .symo's
      # symbols are sed-extracted into cpu.h.  Without TARGET_CPPFLAGS
      # pointing at gnumach's headers, that step can't find <mach/message.h>.
      preConfigure = ''
        export TARGET_CPPFLAGS="-I${gnumach-headers}/include"
        export TARGET_CC=${cc}/bin/${toolPrefix}gcc
      '';

      # Native stdenv wires CC to the host gcc; TARGET_CC (exported in
      # preConfigure) handles the cross-side cpu.symc compile.
      configureFlags = [
        "--target=${target.crossTarget}"
      ];

      # mig is autotools/automake, which declares the codegen ordering
      # (bison/flex -> parser.h/lexxer; cpu.sym -> cpu.h before migcom.c), so
      # the build is parallel-safe - confirmed by long use at `make -j12`.
      enableParallelBuilding = true;

      # Only the CHECKED variant self-tests (see file header): its wrapped cc has
      # glibc-hurd, so the stubs compile.  The bootstrap mig can't (no libc yet)
      # and is upstream of glibc, so it stays unchecked.
      doCheck = checked;

      # Keep mig's `-g` DWARF (CFLAGS is `-g -O2`); the native stdenv fixup strip
      # hook would otherwise discard it.
      dontStrip = true;

      # Disable the patchelf setup-hook's --shrink-rpath pass (would shrink
      # migcom's RPATH on a Linux builder); keep it off for output stability.
      dontPatchELF = true;

      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU MIG cross-compiler for ${target.crossTarget}";
        platforms = platforms.all;
        # `nix run .#mig-<arch>` looks up bin/<mainProgram>; without
        # this it derives the name from pname (mig-<crossTarget>) and
        # fails because the actual wrapper is <crossTarget>-mig.
        mainProgram = "${target.crossTarget}-mig";
      };
    }
    // lib.optionalAttrs checked {
      # test_lib.sh compiles the stubs with `$CC $CFLAGS`; pass the
      # gnumach-headers include via an exported CFLAGS (NOT -ffreestanding - the
      # stubs genuinely need the wrapped cc's hosted <string.h>).
      preCheck = ''
        export CFLAGS="-I${gnumach-headers}/include"
      '';
    }
    // helpers.mkReproAttrs { inherit pname; version = fullVersion; });

  # BOOTSTRAP builds every target; CHECKED only the non-xen userland targets
  # (xen variants share a crossTarget, so a checked xen mig would be redundant).
  migTargets =
    if checked
    then lib.filterAttrs (_: t: (t.platform or null) != "xen") targets
    else targets;
  outPrefix = if checked then "mig-checked-" else "mig-";
in
lib.mapAttrs' (name: target: lib.nameValuePair "${outPrefix}${name}" (mkOne name target)) migTargets
