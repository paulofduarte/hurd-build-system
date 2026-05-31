# GNU Hurd public headers — per-target derivations.
#
# Outputs the include tree downstream consumers (glibc-hurd, the hurd
# userland, downstream packages) need to see:
#
#   $out/include/hurd/...        (Hurd-side type/RPC headers + .defs)
#   $out/include/hurd_types.h    (the AC_CONFIG_SRCDIR sentinel)
#   $out/share/msgids/...        (debugger msgid tables — only if MIG
#                                 generation succeeds at configure time)
#
# Returned shape — one attribute per entry in `targets`, named
# `hurd-headers-<name>`.  Mirrors flakes/gnumach-headers's shape so the
# root flake just merges what comes back into `packages.<system>`.
#
# Toolchain story: this derivation uses the **native** host stdenv
# (build-host gcc), NOT a Hurd cross-toolchain.  `make install-headers`
# is a pure file-copy walk over $(installhdrs) in each sub-Makefile —
# no compilation, no linking — so the Hurd cross-cc is not a
# prerequisite here.  Configure still needs SOME working CC to satisfy
# AC_PROG_CC; host gcc with `--host=i686-gnu --build=<host-tuple>` is
# enough.  False-positive HAVE_* defines from configure's link tests
# don't matter because no .c file ever gets compiled.
#
# Hurd's configure.ac explicitly rejects any --host whose OS isn't
# `gnu*`, so the bare-metal `i686-elf` toolchain the rest of this flake
# uses for the gnumach kernel won't work here — which is why this file
# diverges from flakes/gnumach-headers/default.nix.
#
# MIG is required as a build tool by `AC_CHECK_TOOL([MIG], [mig])`.
# We pull in the matching cross-flavor mig-<migTarget> from the sibling
# flake (already produces `i686-gnu-mig`) — autoconf's host-prefixed
# tool search picks it up via PATH.  The mig output isn't actually
# invoked for install-headers (no .defs → .h codegen happens there);
# the binary just needs to be discoverable so configure doesn't
# AC_MSG_ERROR.
#
# Source comes from the pinned `hurd-src` flake input (savannah master,
# locked in flake.lock).

{ nixpkgs, system, targets, mig, self, srcInput, forkUrl }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };

  # Upstream version parsed from configure.ac (`AC_INIT([GNU Hurd], …)`).
  upstreamVersion = helpers.parseAcInitVersion (srcInput + "/configure.ac");

  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self forkUrl;
  };

  # Hurd userland targets — only i686 / x86_64 today.  Xen variants
  # share the same userland ABI (only gnumach differs by platform), so
  # filter them out; aarch64 is on Sergey's branch, not upstream.
  hurdTargets = lib.filterAttrs
    (name: target:
      (target.crossSystem == "i686-elf" || target.crossSystem == "x86_64-elf")
      && target.platform != "xen")
    targets;

  mkOne = name: target:
    let
      crossMig = mig."mig-${name}";
      pname = "hurd-headers-${target.migTarget}";
    in
    pkgs.stdenv.mkDerivation ({
      inherit pname;
      version = fullVersion;

      # The pinned `hurd-src` input (savannah master locked in flake.lock).
      # Never the local src/hurd working clone — same convention as
      # gnumach / mig.
      src = srcInput;

      # autoreconfHook regenerates configure from configure.ac (the shipped
      # configure script is older than current automake; regenerating
      # ensures the dependency-tracking + per-host hooks match the rest
      # of this flake).  texinfo: hurd's docs build invokes makeinfo
      # transitively — install-headers itself doesn't, but configure
      # checks for it.  perl: some build-time scripts shell out to perl.
      # crossMig: provides `<migTarget>-mig` on PATH so configure's
      # AC_CHECK_TOOL([MIG], [mig]) resolves with the right host prefix.
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ texinfo perl ])
        ++ [ crossMig ];

      # GCC 15+ defaults to C23; pin gnu17 to match the rest of the flake.
      CFLAGS = "-std=gnu17 -g -O2";

      # Splice the eval-time composed version into AC_INIT before
      # autoreconfHook regenerates configure.  Same pattern as
      # flakes/gnumach/ and flakes/mig/.
      postPatch = ''
        sed -i.bak \
          -e 's|^AC_INIT(\[GNU Hurd\], \[[^]]*\],|AC_INIT([GNU Hurd], [${fullVersion}],|' \
          configure.ac
        rm configure.ac.bak
        grep "^AC_INIT" configure.ac
      '';

      # --host=<migTarget> tells configure this is a cross-build (so
      # autoconf skips run-tests and uses link-tests instead).  The
      # link tests then false-positive against the host libc — which
      # is fine for headers-only because we never compile any .c file.
      # --build is set by stdenv to the host system; explicitly
      # passing --host is enough to flip autoconf into cross mode.
      #
      # The `ac_cv_*` lies / disable-* flags break the chicken-and-egg
      # with glibc / libpthread / parted / libtirpc: hurd's configure
      # would otherwise want to link against those libs to test for
      # specific symbols, but we don't have them at headers-only time.
      # Verbatim from Guix's gnu/packages/hurd.scm `hurd-headers`
      # configureFlags.
      configureFlags = [
        "--host=${target.migTarget}"
        "--disable-profile"
        "--disable-ncursesw"
        "--without-parted"
        "--without-libbz2"
        "--without-libz"
        "--without-rump"
        "ac_cv_search_clnt_create=no"  # would otherwise pull in libtirpc
      ];

      # Headers-only — skip the kernel-and-userland compile entirely.
      dontBuild = true;

      installPhase = ''
        runHook preInstall
        make install-headers prefix=$out no_deps=t
        runHook postInstall
      '';

      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU Hurd public headers for ${target.migTarget}";
        platforms = platforms.all;
      };
    } // helpers.mkReproAttrs { inherit pname; version = fullVersion; });
in
lib.mapAttrs' (name: target: lib.nameValuePair "hurd-headers-${name}" (mkOne name target)) hurdTargets
