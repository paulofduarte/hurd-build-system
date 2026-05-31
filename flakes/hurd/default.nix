# GNU Hurd userland — per-target derivations.
#
# Builds the core Hurd servers + libraries with the Hurd cross-toolchain
# (flakes/hurd-toolchain): the wrapped cc, mig, and glibc-hurd as the
# sysroot.  Output layout (hurd's `make install prefix=$out`):
#
#   $out/hurd/...        translators (ext2fs, isofs, pflocal, exec, …)
#   $out/lib/...         the hurd libraries (libports, libdiskfs, …)
#   $out/libexec/...     runsystem + boot helpers
#   $out/include/hurd/...
#   $out/bin, $out/sbin  userland utilities
#
# Optional components with external dependencies (parted, rump, nfs via
# libtirpc, lwip, pci-arbiter/acpi via libpciaccess, console xkbcommon,
# libgcrypt, libdaemon) are disabled for now: the goal here is the core
# ext2fs-bootable userland.  They configure off cleanly — the PKG_CHECK
# probes find nothing with an empty PKG_CONFIG_PATH, and the rest are
# --without-* flags.  Driver/filesystem extras are a follow-up.
#
# Source comes from the pinned `hurd-src` flake input (savannah master,
# locked in flake.lock).
#
# Filtered to targets with a `hurdCrossSystem` field (i686, x86_64).

{ nixpkgs, system, targets, mig, hurdToolchain, glibcHurd, self, srcInput, forkUrl }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };
  # Configure flags shared with the in-tree dev shell (Makefile `make hurd`).
  hurdConfig = import ../hurd-toolchain/hurd-config.nix;

  upstreamVersion = helpers.parseAcInitVersion (srcInput + "/configure.ac");
  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self forkUrl;
  };

  hurdTargets = lib.filterAttrs (name: target: target ? hurdCrossSystem) targets;

  mkOne = name: target:
    let
      tp        = target.migTarget;                       # e.g. i686-gnu
      toolchain = hurdToolchain."hurd-toolchain-${name}"; # wrapped cross cc
      crossMig  = mig."mig-${name}";
      pname     = "hurd-${tp}";
    in
    pkgs.stdenv.mkDerivation ({
      inherit pname;
      version = fullVersion;
      src = srcInput;

      # autoreconfHook regenerates configure; texinfo/perl are build-time
      # needs.  The wrapped cross cc (provides ${tp}-gcc) + cross mig
      # (provides ${tp}-mig) are found by configure's host-prefixed tool
      # search.  pkg-config is present so the optional PKG_CHECK_MODULES
      # probes run and report "not found" rather than erroring.
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ texinfo perl pkg-config ])
        ++ [ toolchain crossMig ];

      # hurd predates gcc's -fno-common default (gcc 10+); -fcommon keeps
      # its tentative-definition globals linking.
      CFLAGS = "-fcommon -g -O2";

      postPatch = ''
        sed -i.bak \
          -e 's|^AC_INIT(\[GNU Hurd\], \[[^]]*\],|AC_INIT([GNU Hurd], [${fullVersion}],|' \
          configure.ac
        rm configure.ac.bak
        grep "^AC_INIT" configure.ac

        # The setuid install ops (mail.local, login, ids, ps, w) pass
        # `-o root -m 4755` to install.  Both fail in the nix sandbox:
        # chown is forbidden, and the store disallows the setuid bit.
        # Strip the owner and drop the setuid bit to a plain 0755 — the
        # setuid owner+bit are a booting-system concern, applied at
        # deploy (nix strips setuid in the store regardless).
        find . -name Makefile -exec sed -i \
          -e 's/-o root //g' -e 's/-m 4755/-m 0755/g' {} +
      '';

      # Empty PKG_CONFIG_PATH → the optional PKG_CHECK_MODULES probes
      # (xkbcommon, blkid, libgcrypt, lwip, pciaccess) find nothing and
      # their components stay off.  CC/MIG are pinned to the cross tools
      # so autoreconfHook's host-gcc setup-hook doesn't shadow them.
      preConfigure = ''
        export PKG_CONFIG_PATH=
        export CC=${tp}-gcc
        export MIG=${tp}-mig
        export USER_MIG=${tp}-mig
      '';

      # Force the cross archiver/ranlib/nm.  hurd's Makeconf archive
      # rule uses $(AR)/$(RANLIB), but those resolve to make's built-in
      # `ar`/`ranlib` (the build host's) — configure's AC_CHECK_TOOL
      # result doesn't reach the recursive sub-makes.  On a non-Linux
      # host the host ar/ranlib can't index i686-gnu ELF objects, so the
      # static archives come out empty ("no global symbols") and every
      # .static program fails to link.  Command-line make vars override
      # the built-ins and propagate to sub-makes.
      makeFlags = [ "AR=${tp}-ar" "RANLIB=${tp}-ranlib" "NM=${tp}-nm" ];

      # Flag set is shared with the in-tree dev shell via hurd-config.nix
      # (the --without-* disables + the cross-configure cache seeds); see
      # that file for the rationale.  Only --host is per-derivation here.
      configureFlags = [ "--host=${tp}" ] ++ hurdConfig.coreFlags;

      installPhase = ''
        runHook preInstall
        make install prefix=$out $makeFlags
        runHook postInstall
      '';

      # Serial build: hurd's top Makefile builds lib-subdirs and
      # prog-subdirs without declaring the prog→lib dependency, so a
      # parallel build races — prog-subdirs (exec, storeio, …) link
      # before lib-subdirs (libports, libtrivfs, libshouldbeinlibc)
      # finish, failing on undefined ports_*/trivfs_* symbols.
      enableParallelBuilding = false;

      passthru = { inherit target; };
      meta = with lib; {
        description = "GNU Hurd userland (core servers) for ${tp}";
        platforms = platforms.all;
        license = licenses.gpl2Plus;
      };
    } // helpers.mkReproAttrs { inherit pname; version = fullVersion; });
in
lib.mapAttrs' (name: target: lib.nameValuePair "hurd-${name}" (mkOne name target)) hurdTargets
