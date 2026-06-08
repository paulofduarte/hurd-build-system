# GNU Hurd userland — per-target derivations.
#
# Builds the core Hurd servers + libraries with the cross-toolchain
# (flakes/cross-toolchain): the wrapped cc, mig, and glibc-hurd as the
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
# Filtered to the non-xen userland targets (i686, x86_64).

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
      # patchelf: the stdenv audit-tmpdir fixup runs `patchelf --print-rpath`
      # on each output ELF to check no $TMPDIR build-dir path leaked into
      # RPATH.  Observed on this host (aarch64-darwin) the default stdenv
      # ships no patchelf, so the audit can't run — it logged "patchelf:
      # command not found".  Add it so the audit works.  Unlike the
      # freestanding kernel, the Hurd userland IS dynamically linked (servers
      # /libs against glibc-hurd) with real RPATHs, so here the audit does
      # genuine work.  dontPatchELF below disables patchelf's OTHER hook
      # (--shrink-rpath), which its setup-hook would otherwise register.
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ texinfo perl pkg-config patchelf fakeroot ])
        ++ [ toolchain crossMig ];

      # CFLAGS are passed via configureFlags (below), NOT as a derivation env var:
      # an env CFLAGS is seen by BOTH configure (→ config.make) AND make, so the
      # `-g/-O/-std` set lands in DW_AT_producer twice — diverging from the in-tree
      # build, which passes CFLAGS through configure only.  The toolchain debug-
      # prefix-map moves to NIX_CFLAGS_COMPILE (preBuild), the same channel the
      # in-tree dev shell uses, so neither doubles.

      postPatch = ''
        sed -i.bak \
          -e 's|^AC_INIT(\[GNU Hurd\], \[[^]]*\],|AC_INIT([GNU Hurd], [${fullVersion}],|' \
          configure.ac
        rm configure.ac.bak
        grep "^AC_INIT" configure.ac
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
        # CFLAGS via configureFlagsArray (a bash array) so the embedded space
        # survives — a plain configureFlags list element is word-split by nix.
        configureFlagsArray+=("CFLAGS=${buildFlags.hurdExtraCflags} ${buildFlags.baseCflags}")
        ${helpers.crossPkg.outOfTreePreConfigure}
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
      # Deployable prefix (mirrors the in-tree build + glibc.nix's deployPrefix):
      # configure --prefix=/ with root-relative dirs so baked paths — libps's
      # DATADIR (=//share/msgids), the console server's module dir + .bdf font
      # dir — are deployable and match the in-tree, NOT $out store paths (which
      # also make the dist non-deployable).  dontAddPrefix stops stdenv adding
      # --prefix=$out; install lands in $out via DESTDIR.  No --datarootdir, so
      # datadir defaults to //share like the in-tree.
      configureFlags = [
        "--host=${tp}"
      ] ++ hurdConfig.deployFlags ++ hurdConfig.coreFlags;
      dontAddPrefix = true;

      # Install under fakeroot: hurd's daemons/ + utils/ install some programs
      # `-o root -m 4755` (setuid), which the sandbox can't do (chown is
      # forbidden, the store disallows setuid).  fakeroot fakes the chown +
      # setuid so the install completes; the bits don't persist (nix strips
      # setuid in the store regardless — they're a deploy-time concern), so
      # the outcome matches the host `make dist-hurd` path.  This replaces the
      # old find|sed that rewrote `-o root -m 4755` → `-m 0755` in the source
      # Makefiles, keeping the source unmutated.
      installPhase = ''
        runHook preInstall
        fakeroot make install DESTDIR=$out $makeFlags
        runHook postInstall
      '';

      # Parallel build — a calculated bet, not a guarantee.  hurd's top
      # Makefile still does NOT declare any prog→lib ordering: each subdir is
      # `$(prog-subdirs) $(lib-subdirs): FORCE` (verified in src/hurd HEAD,
      # 1495073d), and `all:` just lists lib-subdirs then prog-subdirs flat —
      # nothing stops a prog-subdir (exec/storeio) from reaching its link step
      # before a lib-subdir (libports/libtrivfs/libshouldbeinlibc) it needs has
      # built → undefined ports_*/trivfs_*.  So the failure is a timing/-j
      # race, latent not structural: lib-subdirs are listed first so make
      # tends to start them first and they usually finish in time, which is
      # why moderate-`-j` builds (in-tree and nix) pass.  We enable it for the
      # speedup; if a high-`-j` build ever fails on undefined ports_*/trivfs_*,
      # that's this race — revert to false.
      enableParallelBuilding = true;

      # Disable the `--shrink-rpath` patchELF fixup hook on the cross userland
      # ELFs.  The patchelf in nativeBuildInputs above (for the audit) also
      # registers patchelf's setup-hook, which would otherwise run
      # `patchelf --shrink-rpath` on every output and mutate the servers'/libs'
      # RPATHs; we keep that off for output stability.  dontPatchELF guards
      # ONLY the shrink hook — the audit-tmpdir check still runs.
      dontPatchELF = true;

      # Keep the deployable `#!/bin/bash` shebangs in the installed hurd scripts
      # (rc, runsystem, MAKEDEV, fakeroot, …).  nixpkgs' patchShebangs fixup
      # rewrites them to `#!/nix/store/…/bash`, which (a) isn't deployable on a
      # target Hurd and (b) diverges from the in-tree `make install` (no such
      # rewrite).  The dist ships these to /libexec, /sbin, /bin root-relative.
      dontPatchShebangs = true;

      # Keep the userland's `-g` DWARF (CFLAGS is `-fcommon -g -O2`); the
      # stdenv fixup strip hook would otherwise discard it.  hurd's own
      # install (INSTALL_PROGRAM) carries no -s, so this is the only stripper.
      # Want dist/ debuggable (gdb / addr2line on the servers + libs).
      dontStrip = true;

      # Keep a REAL $out/sbin.  nixpkgs' move-sbin.sh fixup hook (native stdenv)
      # otherwise moves $out/sbin/* into $out/bin and replaces sbin with a
      # symlink -> bin.  That is NOT the GNU/Hurd layout: hurd installs sutils
      # (fsck/halt/swapon/MAKEDEV) to a distinct $(sbindir) and even ships
      # bin/MAKEDEV -> ../sbin/MAKEDEV — and Debian GNU/Hurd keeps /sbin real
      # too.  The hook also (a) breaks that MAKEDEV link, (b) diverges from the
      # in-tree `make install` (no such hook → real /sbin), and (c) collides on
      # the shared dist tree with glibc's real sbin/ (sln/zic/iconvconfig) when
      # dist-hurd + dist-glibc cp -a into it.  Disabling it keeps nix == in-tree
      # == Debian and makes the dist merge order-independent.
      dontMoveSbin = true;

      passthru = { inherit target; };
      meta = with lib; {
        description = "GNU Hurd userland (core servers) for ${tp}";
        platforms = platforms.all;
        license = licenses.gpl2Plus;
      };

      # Determinism — make the nix userland BYTE-IDENTICAL to the in-tree build of
      # the same source (mirrors flakes/cross-toolchain/glibc.nix + the in-tree
      # Makefile recipe).  hurd builds OUT-OF-TREE here ($srcdir ≠ $PWD), both
      # mapped to the SINGLE canonical the in-tree build also maps src+build to
      # (build-flags.nix hurdCanonBuild), so DWARF paths agree.  Pin the shared
      # -frandom-seed (stripping the reproducible-builds hook's $out-derived one).
      # ALSO strip host build-tool `-isystem /nix/store/*` (+ their macro-prefix-
      # maps): the native stdenv dumps every nativeBuildInput's include dir into
      # NIX_CFLAGS_COMPILE, and on darwin the HOST libiconv-dev lands ahead of the
      # target glibc, so console/pc_kbd/vga compile against the wrong iconv.h and
      # leak the host store path into DWARF (Linux glibc has iconv built in → no
      # leak).  A cross-compile must resolve system headers from its own sysroot
      # only — the same strip the dev-shell does.  Replaces helpers.mkReproAttrs.
      preBuild = ''
        ${buildFlags.detCflagsExport { inherit toolchain; canonBuild = buildFlags.hurdCanonBuild; stripIsystem = true; }}
      '';
    });
in
lib.mapAttrs' (name: target: lib.nameValuePair "hurd-${name}" (mkOne name target)) hurdTargets
