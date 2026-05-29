# GNU MIG — per-target cross-compiler derivations.
#
# One nix derivation per target (autoreconf + configure + make +
# make install) producing the per-target MIG binary and its companion
# migcom under $out/{bin,libexec}.
#
# `doCheck = true` runs MIG's own `make check` (good/, bad/, generate-only/
# subsuites — 12 tests on master/cross-test-cpp) inside the sandbox.
# These exercise the host-side codegen path: cpp the .defs, run migcom,
# compile the generated stubs.  The test_lib.sh harness (after the
# cross-test-cpp fix landed) uses `$CC -E -x c` for the cpp step, so
# preprocessing is target-aware — what makes cross-test reliable.
#
# Returned shape — one attribute per entry in `targets`, named
# `mig-<name>`.  The root flake just merges what comes back into
# `packages.<system>`.
#
# Per-target attrset fields (mirrors flake.nix):
#   crossSystem : nixpkgs cross-system identifier — drives TARGET_CC
#                 (the compiler that builds cpu.symc + compiles test stubs).
#   migTarget   : the triple passed to ./configure --target=.  Also
#                 used to compose the output binary name
#                 (<migTarget>-mig + <migTarget>-migcom).
#   platform    : unused by MIG (gnumach-side concern); accepted in
#                 the attrset for symmetry with gnumach-headers.
#
# Source comes from ../../src/mig (the git submodule).  The root flake's
# `inputs.self.submodules = true;` is what makes the submodule content
# visible to the nix store at fingerprint time.
#
# `gnumachHeaders` is the attrset returned by flakes/gnumach-headers
# (the sibling sub-flake).  We look up "gnumach-headers-<name>" for the
# matching target so cpu.sym sees <mach/message.h>.
#
# Build-time dependencies:
#   - autoreconfHook (autoconf/automake/libtool/m4) + bison/flex for MIG's
#     own parser.y / lexxer.l.  awk comes from stdenv; perl is not needed to
#     build MIG (only its installed wrapper shells out to perl at run time).
#   - Native gcc for migcom itself (MIG is a build-host tool).
#   - Cross cc for TARGET_CC (cpu.sym compilation + test-suite stub builds).
#   - gnumach-headers for the target arch — TARGET_CPPFLAGS points at
#     $gnumach-headers/include so cpu.symc sees <mach/message.h> etc.

{ nixpkgs, system, targets, gnumachHeaders, mkCrossPkgs, self, srcInput }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };

  # Upstream version parsed from configure.ac (AC_INIT line).  If
  # upstream bumps, the parser picks it up automatically.
  upstreamVersion = helpers.parseAcInitVersion ../../src/mig/configure.ac;

  # PACKAGE_VERSION composed at eval time — fully pure.
  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self;
    submodulePath = "src/mig";
  };

  mkOne = name: target:
    let
      gnumach-headers = gnumachHeaders."gnumach-headers-${name}";
      crossPkgs = mkCrossPkgs system target;
      inherit (crossPkgs.stdenv) cc;
      toolPrefix = cc.targetPrefix;
      pname = "mig-${target.migTarget}";
    in
    # Native stdenv: MIG itself is a host tool.  Cross tools come in via
    # nativeBuildInputs + explicit env vars below.
    pkgs.stdenv.mkDerivation ({
      inherit pname;

      # Drives both the store path suffix and (via the sed below) the
      # binary's PACKAGE_VERSION — same string, traceable on both sides.
      version = fullVersion;

      # See the matching note in flakes/gnumach/default.nix: src comes
      # from the locked flake input so the built bytes match the rev
      # the version string advertises.  Uncommitted edits in src/mig
      # are intentionally invisible to nix builds (use `make mig` for
      # iterative dev — that path bypasses nix).
      src = srcInput;

      # autoreconfHook supplies autoconf/automake/libtool/m4 + runs autoreconf.
      # bison/flex are MIG's own needs (parser.y + lexxer.l); awk comes from
      # stdenv.  The cross cc is for TARGET_CC (cpu.symc) + the test stubs.
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ bison flex ])
        ++ [ crossPkgs.stdenv.cc ];

      # Pinned at the same gnu17 the dev shell uses — keeps cross- and
      # native-arch builds consistent.
      CFLAGS = "-std=gnu17 -g -O2";

      # Splice the eval-time-composed version into AC_INIT before the
      # autoreconfHook regenerates configure.  ${fullVersion} is composed
      # from upstream + submodule input metadata + .gitmodules + self.
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
        export TARGET_CC=${crossPkgs.stdenv.cc}/bin/${toolPrefix}gcc
      '';

      # --prefix is injected by stdenv's configurePhase (from $prefix=$out).
      # Native stdenv already wires CC to the host gcc — TARGET_CC (exported
      # in preConfigure) is what handles the cross-side cpu.symc compile.
      configureFlags = [
        "--target=${target.migTarget}"
      ];

      # Run MIG's host-side codegen test-suite inside the sandbox.
      # AM_TESTS_ENVIRONMENT (tests/Makeconf.am) re-exports CC as
      # $(TARGET_CC), so the test_lib.sh harness preprocesses with the
      # target compiler — matches cross-build semantics.
      doCheck = true;

      # test_lib.sh compiles the generated -server.c / -user.c stubs with
      # $CC $CFLAGS.  Those stubs `#include <mach/boolean.h>` etc., so the
      # cross compiler needs the gnumach-headers include path on its search
      # list at check time.  AM_TESTS_ENVIRONMENT (tests/Makeconf.am) only
      # forwards SRCDIR/BUILDDIR/CC — not CFLAGS — so a bare env export
      # wouldn't reach the test process.  Pass it via TESTS_ENVIRONMENT,
      # which automake concatenates with AM_TESTS_ENVIRONMENT for each test.
      checkFlags = [
        "TESTS_ENVIRONMENT=CFLAGS=-I${gnumach-headers}/include"
      ];

      # Add a cross-toolchain-prefixed alias next to the primary binary.
      # Two naming conventions intersect on MIG:
      #   - Primary: <migTarget>-mig (e.g. aarch64-gnu-mig) — what
      #     `./configure --target=<migTarget>` produces, and what every
      #     Hurd-side consumer (the userland servers, glibc) expects
      #     because they configure with --host=<arch>-gnu.
      #   - Alias: <crossPrefix>mig (e.g. aarch64-unknown-none-elf-mig)
      #     — what gnumach's `AC_CHECK_TOOL([MIG], [mig])` searches for
      #     when the kernel is cross-built with a bare-metal toolchain
      #     (--host=<crossPrefix>).  Without this alias, gnumach's
      #     configure falls through to MIG=:, codegen no-ops, and the
      #     first compile fails on a missing .server.h.
      # Both consumers self-discover via PATH; no `MIG=` override needed.
      postInstall = ''
        ln -s ${target.migTarget}-mig \
          $out/bin/${toolPrefix}mig
      '';

      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU MIG cross-compiler for ${target.migTarget}";
        platforms = platforms.all;
        # `nix run .#mig-<arch>` looks up bin/<mainProgram>; without
        # this it derives the name from pname (mig-<migTarget>) and
        # fails because the actual wrapper is <migTarget>-mig.
        mainProgram = "${target.migTarget}-mig";
      };
    } // helpers.mkReproAttrs { inherit pname; version = fullVersion; });
in
lib.mapAttrs' (name: target: lib.nameValuePair "mig-${name}" (mkOne name target)) targets
