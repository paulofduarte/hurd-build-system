# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# GNU Hurd userland - per-target derivations.  Builds the core servers +
# libraries with the cross-toolchain (wrapped cc, mig, glibc-hurd sysroot).
# Output layout (hurd's `make install prefix=$out`):
#
#   $out/hurd/...        translators (ext2fs, isofs, pflocal, exec, ...)
#   $out/lib/...         the hurd libraries (libports, libdiskfs, ...)
#   $out/libexec/...     runsystem + boot helpers
#   $out/include/hurd/...
#   $out/bin, $out/sbin  userland utilities
#
# Optional components with external deps (parted, rump, nfs, lwip, pci-arbiter/
# acpi, console xkbcommon, libgcrypt, libdaemon) are disabled - the goal is the
# core ext2fs-bootable userland.  They configure off cleanly (empty
# PKG_CONFIG_PATH + --without-* flags); driver/filesystem extras are a follow-up.
#
# Source comes from the pinned `hurd-src` flake input.  Filtered to the non-xen
# userland targets (i686, x86_64).

{ nixpkgs, system, targets, mig, hurdToolchain, glibcHurd, self, srcInput, forkUrl }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };
  # Configure flags shared with the in-tree dev shell (Makefile `make hurd`).
  hurdConfig = import ../cross-toolchain/hurd-config.nix;
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  upstreamVersion = helpers.parseAcInitVersion (srcInput + "/configure.ac");
  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self forkUrl;
  };

  hurdTargets = lib.filterAttrs (name: target: (target.platform or null) != "xen") targets;

  mkOne = name: target:
    let
      tp        = target.crossTarget;                       # e.g. i686-gnu
      toolchain = hurdToolchain."toolchain-${name}";      # wrapped cross cc
      crossMig  = mig."mig-${name}";
      pname     = "hurd-${tp}";
      # The cc-wrapper suffix salt (NIX_*_<salt>), matching wrapCCWith's.
      salt      = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] tp;
    in
    pkgs.stdenv.mkDerivation ({
      inherit pname;
      version = fullVersion;
      src = srcInput;

      # autoreconfHook regenerates configure; texinfo/perl are build-time needs.
      # The wrapped cross cc (${tp}-gcc) + cross mig (${tp}-mig) are found by
      # configure's host-prefixed tool search.  pkg-config: so the optional
      # PKG_CHECK_MODULES probes report "not found" rather than erroring.
      # patchelf: the stdenv audit-tmpdir fixup runs `patchelf --print-rpath` on
      # each output ELF; the default darwin stdenv ships none, so add it.  Unlike
      # the freestanding kernel, the userland IS dynamically linked with real
      # RPATHs, so the audit does genuine work.  dontPatchELF below disables
      # patchelf's OTHER hook (--shrink-rpath).
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ texinfo perl pkg-config patchelf fakeroot ])
        ++ [ toolchain crossMig ];

      # CFLAGS go via configureFlags (below), NOT a derivation env var: an env
      # CFLAGS is seen by configure (-> config.make) AND make, so `-g/-O/-std` land
      # in DW_AT_producer twice vs the in-tree build (configure-only).  The
      # toolchain debug-prefix-map moves to NIX_CFLAGS_COMPILE (preBuild).

      postPatch = ''
        sed -i.bak \
          -e 's|^AC_INIT(\[GNU Hurd\], \[[^]]*\],|AC_INIT([GNU Hurd], [${fullVersion}],|' \
          configure.ac
        rm configure.ac.bak
        grep "^AC_INIT" configure.ac
      '';

      # Empty PKG_CONFIG_PATH -> the optional PKG_CHECK_MODULES probes find
      # nothing and their components stay off.  CC/MIG pinned to the cross tools
      # so autoreconfHook's host-gcc setup-hook doesn't shadow them.
      preConfigure = ''
        export PKG_CONFIG_PATH=
        export CC=${tp}-gcc
        export MIG=${tp}-mig
        export USER_MIG=${tp}-mig
        # CFLAGS via configureFlagsArray (a bash array) so the embedded space
        # survives - a plain configureFlags list element is word-split by nix.
        configureFlagsArray+=("CFLAGS=${buildFlags.hurdExtraCflags} ${buildFlags.baseCflags}")
        ${helpers.crossPkg.outOfTreePreConfigure}
      '';

      # Force the cross archiver/ranlib/nm.  hurd's Makeconf archive rule uses
      # $(AR)/$(RANLIB), but those resolve to make's built-in (host) `ar`/`ranlib`
      # - configure's AC_CHECK_TOOL result doesn't reach the sub-makes.  On a
      # non-Linux host the host ar/ranlib can't index i686-gnu ELF, so the static
      # archives come out empty and every .static program fails to link.
      # Command-line make vars override the built-ins and propagate.
      makeFlags = [ "AR=${tp}-ar" "RANLIB=${tp}-ranlib" "NM=${tp}-nm" ];

      # Flag set shared with the in-tree dev shell via hurd-config.nix (see that
      # file); only --host is per-derivation here.  Deployable prefix (mirrors
      # the in-tree build + glibc.nix's deployPrefix): configure --prefix=/ with
      # root-relative dirs so baked paths (libps's DATADIR, the console server's
      # module + .bdf font dirs) are deployable and match the in-tree, NOT $out
      # store paths.  dontAddPrefix stops stdenv adding --prefix=$out; install
      # lands in $out via DESTDIR.  No --datarootdir, so datadir defaults to
      # //share like the in-tree.
      configureFlags = [
        "--host=${tp}"
      ] ++ hurdConfig.deployFlags ++ hurdConfig.coreFlags;
      dontAddPrefix = true;

      # Install under fakeroot: hurd's daemons/ + utils/ install some programs
      # `-o root -m 4755` (setuid), which the sandbox can't do (chown forbidden,
      # store disallows setuid).  fakeroot fakes the chown + setuid so the install
      # completes; the bits don't persist (nix strips setuid in the store - a
      # deploy-time concern), so the outcome matches the host `make dist-hurd`
      # path while keeping the source unmutated.
      installPhase = ''
        runHook preInstall
        fakeroot make install DESTDIR=$out $makeFlags
        runHook postInstall
      '';

      # Parallel build - a calculated bet, not a guarantee.  hurd's top Makefile
      # declares NO prog->lib ordering (each subdir is `... : FORCE`), so nothing
      # stops a prog-subdir reaching its link before a lib-subdir it needs has
      # built -> undefined ports_*/trivfs_*.  Latent, not structural: lib-subdirs
      # are listed first so make tends to start them first and they usually
      # finish in time, which is why moderate-`-j` builds pass.  If a high-`-j`
      # build ever fails on undefined ports_*/trivfs_*, that's this race - revert
      # to false.
      enableParallelBuilding = true;

      # Disable the `--shrink-rpath` patchELF hook (registered by the patchelf in
      # nativeBuildInputs) - keep it from mutating the servers'/libs' RPATHs, for
      # output stability.  dontPatchELF guards ONLY this hook; the audit-tmpdir
      # check still runs.
      dontPatchELF = true;

      # Keep the deployable `#!/bin/bash` shebangs in the installed hurd scripts.
      # nixpkgs' patchShebangs rewrites them to `#!/nix/store/.../bash`, which isn't
      # deployable on a target Hurd and diverges from the in-tree `make install`.
      dontPatchShebangs = true;

      # Keep the userland's `-g` DWARF (CFLAGS is `-fcommon -g -O2`); the stdenv
      # fixup strip hook would otherwise discard it.  hurd's own install carries
      # no -s, so this is the only stripper.  Want dist/ debuggable.
      dontStrip = true;

      # Keep a REAL $out/sbin.  nixpkgs' move-sbin.sh fixup otherwise moves
      # $out/sbin/* into $out/bin and symlinks sbin -> bin - NOT the GNU/Hurd
      # layout: hurd installs sutils to a distinct $(sbindir) and ships
      # bin/MAKEDEV -> ../sbin/MAKEDEV; Debian GNU/Hurd keeps /sbin real too.  The
      # hook also breaks that MAKEDEV link, diverges from the in-tree install, and
      # collides on the shared dist tree with glibc's real sbin/ (sln/zic/
      # iconvconfig).  Disabling it keeps nix == in-tree == Debian and makes the
      # dist merge order-independent.
      dontMoveSbin = true;

      passthru = { inherit target; };
      meta = with lib; {
        description = "GNU Hurd userland (core servers) for ${tp}";
        platforms = platforms.all;
        license = licenses.gpl2Plus;
      };

      # Determinism - make the nix userland BYTE-IDENTICAL to the in-tree build.
      # hurd builds OUT-OF-TREE ($srcdir != $PWD), both mapped to the SINGLE
      # canonical the in-tree build maps src+build to (build-flags.nix
      # hurdCanonBuild) so DWARF paths agree.  Pin the shared -frandom-seed.
      # ALSO strip host build-tool `-isystem /nix/store/*`: the native stdenv
      # dumps every nativeBuildInput's include dir into NIX_CFLAGS_COMPILE, and on
      # darwin the HOST libiconv-dev lands ahead of the target glibc, so
      # console/pc_kbd/vga compile against the wrong iconv.h and leak the host
      # store path into DWARF (Linux glibc has iconv built in -> no leak).  A
      # cross-compile must resolve system headers from its own sysroot only.
      # No /nix/store DT_RUNPATH in the shipped servers/libs (Debian GNU/Hurd
      # parity; libs resolve from /lib via the loader).  Two injectors on LINUX
      # (darwin has neither, hence the cross-host divergence):
      #  - the ld-wrapper's per--L rpath derivation - gated by the env attr below
      #    (same channel glibc.nix uses);
      #  - the NATIVE stdenv cc-wrapper hook's explicit `-rpath $out/lib` in the
      #    PLAIN NIX_LDFLAGS (mangleVarList folds it into the salted var at cross-
      #    link time) - NOT covered by NIX_DONT_SET_RPATH (the dev shell verified
      #    this on Linux), so sed it out of the plain var, mirroring dev-shell.nix.
      preBuild = ''
        ${buildFlags.detCflagsExport { inherit toolchain; canonBuild = buildFlags.hurdCanonBuild; stripIsystem = true; }}
        export NIX_LDFLAGS="$(printf '%s' "''${NIX_LDFLAGS:-}" | sed "s@-rpath $out/lib@@g")"
      '';
      "NIX_DONT_SET_RPATH${salt}" = "1";
    });
in
lib.mapAttrs' (name: target: lib.nameValuePair "hurd-${name}" (mkOne name target)) hurdTargets
