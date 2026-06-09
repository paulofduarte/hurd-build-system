# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# GNU Hurd public headers - per-target derivations, one `hurd-headers-<name>`
# per entry in `targets`.  Outputs the include tree downstream consumers
# (glibc-hurd, the hurd userland) need:
#
#   $out/include/hurd/...        (Hurd-side type/RPC headers + .defs)
#   $out/include/hurd_types.h    (the AC_CONFIG_SRCDIR sentinel)
#   $out/share/msgids/...        (debugger msgid tables - only if MIG
#                                 generation succeeds at configure time)
#
# Uses the **native** host stdenv, NOT a Hurd cross-toolchain: `make
# install-headers` is a pure file-copy walk (no compilation), so configure
# only needs SOME CC to satisfy AC_PROG_CC; host gcc with `--host=i686-gnu
# --build=<host-tuple>` is enough, and its false-positive HAVE_* defines don't
# matter because no .c is compiled.  (Hurd's configure.ac rejects any --host
# whose OS isn't `gnu*`, so the bare-metal `i686-elf` toolchain won't work here
# - which is why this diverges from flakes/gnumach-headers.)
#
# MIG is required by `AC_CHECK_TOOL([MIG], [mig])`; we pull in the cross-flavor
# mig-<crossTarget> so autoconf's host-prefixed search finds it via PATH.  It's
# never invoked (no .defs -> .h codegen happens), just needs to be discoverable.
#
# Source comes from the pinned `hurd-src` flake input.

{ nixpkgs, system, targets, mig, srcInput, forkUrl }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  # Upstream version parsed from configure.ac (`AC_INIT([GNU Hurd], ...)`).
  upstreamVersion = helpers.parseAcInitVersion (srcInput + "/configure.ac");

  fullVersion = helpers.composeToolchainVersion {
    inherit upstreamVersion srcInput forkUrl;
  };

  # Hurd userland targets - the non-xen ones.  The xen variants share their CPU
  # sibling's userland ABI (only gnumach differs by platform), so excluded.
  hurdTargets = lib.filterAttrs (name: target: (target.platform or null) != "xen") targets;

  mkOne = name: target:
    let
      crossMig = mig."mig-${name}";
      pname = "hurd-headers-${target.crossTarget}";
    in
    pkgs.stdenv.mkDerivation ({
      inherit pname;
      version = fullVersion;

      # The pinned `hurd-src` input, never the local src/hurd clone.
      src = srcInput;

      # autoreconfHook regenerates configure (the shipped script is older than
      # current automake).  texinfo: configure checks for it.  perl: some
      # build-time scripts shell out to perl.  crossMig: provides
      # `<crossTarget>-mig` on PATH so AC_CHECK_TOOL([MIG], [mig]) resolves.
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ texinfo perl ])
        ++ [ crossMig ];

      CFLAGS = buildFlags.baseCflags;

      # Splice the composed version into AC_INIT before autoreconfHook
      # regenerates configure.
      postPatch = ''
        sed -i.bak \
          -e 's|^AC_INIT(\[GNU Hurd\], \[[^]]*\],|AC_INIT([GNU Hurd], [${fullVersion}],|' \
          configure.ac
        rm configure.ac.bak
        grep "^AC_INIT" configure.ac
      '';

      # --host=<crossTarget> flips autoconf into cross mode (link-tests, not
      # run-tests); the link tests false-positive against the host libc, fine for
      # headers-only since no .c is compiled.  The `ac_cv_*` lies / disable-*
      # flags break the chicken-and-egg with glibc/libpthread/parted/libtirpc,
      # which we don't have at headers-only time.  Verbatim from Guix's
      # gnu/packages/hurd.scm `hurd-headers`.
      configureFlags = [
        "--host=${target.crossTarget}"
        "--disable-profile"
        "--disable-ncursesw"
        "--without-parted"
        "--without-libbz2"
        "--without-libz"
        "--without-rump"
        "ac_cv_search_clnt_create=no"  # would otherwise pull in libtirpc
      ];

      # Headers-only - skip the kernel-and-userland compile entirely.
      dontBuild = true;

      installPhase = ''
        runHook preInstall
        make install-headers prefix=$out no_deps=t
        runHook postInstall
      '';

      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU Hurd public headers for ${target.crossTarget}";
        platforms = platforms.all;
      };
    } // helpers.mkReproAttrs { inherit pname; version = fullVersion; });
in
lib.mapAttrs' (name: target: lib.nameValuePair "hurd-headers-${name}" (mkOne name target)) hurdTargets
