# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# GNU Hurd userland - per-target derivations.  Builds the core servers + libraries
# with the from-source cross-toolchain (unwrapped cross-gcc + cross-binutils, mig, and
# the glibc-hurd sysroot baked via the cross-gcc's --with-sysroot).
# Output layout (hurd's `make install prefix=$out`):
#
#   $out/hurd/...        translators (ext2fs, isofs, pflocal, exec, ...)
#   $out/lib/...         the hurd libraries (libports, libdiskfs, ...)
#   $out/libexec/...     runsystem + boot helpers
#   $out/include/hurd/...
#   $out/bin, $out/sbin  userland utilities
#
# The rump chain is ON (step-5 flip): rumpdisk/rumpnet/pci-arbiter/acpi build
# against the cross zlib/libpciaccess/libacpica/rumpkernel packages (plus
# hurd's own libirqhelp), giving the full 5-module storage boot chain +
# the rumpnet network driver.  The remaining optional components (parted,
# nfs/libtirpc, lwip, xkbcommon, libgcrypt, libdaemon) stay off via
# hurd-config.nix coreFlags.  The IN-TREE `make hurd` keeps the rump chain
# off (noRumpFlags) until the rumpkernel scaffolding task.
#
# Source comes from the pinned `hurd-toolchain-src` flake input.  Filtered to the non-xen
# userland targets (i686, x86_64).

{
  nixpkgs,
  system,
  targets,
  mig,
  toolchainFor,
  self,
  srcInput,
  forkUrl,
  # Rump-chain deps (step-5 flip): zlib (rumpdisk links -lz), libpciaccess
  # (pci-arbiter's pkg-config gate + rump PCI), libacpica (acpi translator),
  # rumpkernel (the librump* set).  libirqhelp comes from hurd's own tree.
  zlib,
  libpciaccess,
  libacpica,
  rumpkernel,
  buildRevToken ? null,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  helpers = import ../lib { inherit lib; };
  # Configure flags shared with the in-tree dev shell (Makefile `make hurd`).
  hurdConfig = import ../cross-toolchain/hurd-config.nix;
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  upstreamVersion = helpers.parseAcInitVersion (srcInput + "/configure.ac");
  fullVersion = helpers.composeVersion {
    inherit
      upstreamVersion
      srcInput
      self
      forkUrl
      buildRevToken
      ;
  };

  hurdTargets = lib.filterAttrs (_name: target: (target.platform or null) != "xen") targets;

  mkOne =
    name: target:
    let
      tp = target.crossTarget; # e.g. i686-gnu
      # The from-source toolchain: unwrapped cross-gcc + cross-binutils.  The cross-gcc
      # bakes --with-sysroot=glibc-hurd (libc + merged mach/hurd headers + glibc's RPC
      # stub libs), so the userland compiles+links against it directly - no wrapper, and
      # no bare-name GROUP rewrite (the raw ld resolves the libc.so /lib GROUP under the
      # sysroot).
      tc = toolchainFor target;
      inherit (tc) cc; # cross-gcc-<arch>      (${tp}-gcc/-g++, glibc sysroot)
      binu = tc.binutils; # cross-binutils-<arch> (${tp}-ar/-ranlib/-nm)
      crossMig = mig."mig-${name}";
      zlibPkg = zlib."zlib-${name}";
      pciPkg = libpciaccess."libpciaccess-${name}";
      acpicaPkg = libacpica."libacpica-${name}";
      rumpPkg = rumpkernel."rumpkernel-${name}";
      pname = "hurd-${tp}";
    in
    pkgs.stdenv.mkDerivation {
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
      nativeBuildInputs = [
        pkgs.autoreconfHook
      ]
      ++ (with pkgs; [
        texinfo
        perl
        pkg-config
        patchelf
        fakeroot
      ])
      ++ [
        cc
        binu
        crossMig
      ];

      # CFLAGS go via configureFlags (below), NOT a derivation env var: an env
      # CFLAGS is seen by configure (-> config.make) AND make, so `-g/-O/-std` land
      # in DW_AT_producer twice vs the in-tree build (configure-only).  The
      # debug-prefix-maps go via CPPFLAGS (preConfigure) - the raw cross-gcc has no
      # wrapper NIX_CFLAGS_COMPILE channel.

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
        # Rump-chain deps (step-5 flip).  pciaccess.pc is deployable
        # (prefix=/usr), so pkg-config needs --define-prefix to derive the
        # real store prefix from the .pc location; everything else rides
        # explicit -I/-L (appended to CPPFLAGS AFTER the determinism maps
        # below, and to LDFLAGS - hurd's Makeconf carries LDFLAGS into every
        # link, so rumpdisk/rumpnet/acpi resolve -lrump*/-lacpica/-lz there).
        export PKG_CONFIG_PATH=${pciPkg}/usr/lib/pkgconfig
        export PKG_CONFIG="pkg-config --define-prefix"
        # Both -L (direct link resolution) AND -rpath-link (GNU ld does NOT
        # consult -L when resolving a shared lib's transitive DT_NEEDED - e.g.
        # swapon links libstore.so which NEEDs libz.so.1).  --as-needed makes
        # configure's HAVE_LIBRUMP probe pass (Guix-proven): librump.so has NO
        # DT_NEEDED on librumpuser (the hypercall layer is consumer-linked),
        # so a bare `-lrump` link trips ld's shlib-undefined check - but the
        # probe program references no rump symbol, so --as-needed drops the
        # lib from the test link entirely; real consumers (rumpdisk) link the
        # full explicit -lrump* set.
        export LDFLAGS="-Wl,--as-needed -L${rumpPkg}/usr/lib -Wl,-rpath-link=${rumpPkg}/usr/lib -L${pciPkg}/usr/lib -Wl,-rpath-link=${pciPkg}/usr/lib -L${acpicaPkg}/usr/lib -Wl,-rpath-link=${acpicaPkg}/usr/lib -L${zlibPkg}/usr/lib -Wl,-rpath-link=${zlibPkg}/usr/lib ''${LDFLAGS:-}"
        export CC=${tp}-gcc
        export MIG=${tp}-mig
        export USER_MIG=${tp}-mig
        # CFLAGS via configureFlagsArray (a bash array) so the embedded space
        # survives - a plain configureFlags list element is word-split by nix.
        configureFlagsArray+=("CFLAGS=${buildFlags.hurdExtraCflags} ${buildFlags.baseCflags}")
        ${helpers.crossPkg.outOfTreePreConfigure}
        # Determinism maps via CPPFLAGS (the raw cross-gcc ignores NIX_CFLAGS_COMPILE);
        # after outOfTreePreConfigure so $srcdir is set and configure bakes it.
        ${buildFlags.detCppflagsUnwrapped {
          gcc = cc;
          binutils = binu;
          canonBuild = buildFlags.hurdCanonBuild;
          inherit (tc) sysroot;
        }}
        export CPPFLAGS="$CPPFLAGS -I${rumpPkg}/usr/include -I${pciPkg}/usr/include -I${acpicaPkg}/usr/include -I${zlibPkg}/usr/include"
      '';

      # Force the cross archiver/ranlib/nm.  hurd's Makeconf archive rule uses
      # $(AR)/$(RANLIB), but those resolve to make's built-in (host) `ar`/`ranlib`
      # - configure's AC_CHECK_TOOL result doesn't reach the sub-makes.  On a
      # non-Linux host the host ar/ranlib can't index i686-gnu ELF, so the static
      # archives come out empty and every .static program fails to link.
      # Command-line make vars override the built-ins and propagate.
      # hurddir=/hurd pins the servers dir to top-level /hurd: config.make.in sets
      # `hurddir = ${exec_prefix}/hurd`, which under --prefix=/usr would install
      # servers to /usr/hurd, but the boot chain (/hurd/ext2fs.static ...) and distro
      # overlays expect /hurd (Debian keeps it unmerged).  A command-line make var
      # overrides the config.make assignment at both build + install.
      makeFlags = [
        "AR=${tp}-ar"
        "RANLIB=${tp}-ranlib"
        "NM=${tp}-nm"
        "hurddir=/hurd"
      ];

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
      ]
      ++ hurdConfig.deployFlags
      ++ hurdConfig.coreFlags;
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

      # Serial library pass, then parallel everything else.  hurd's build has NO -j-safe
      # inter-subdir ordering: subdirs are `... : FORCE` and the cross-subdir auto-build
      # rule (../%.a ../%.so) is commented OUT in Makeconf - it RELIES on building the
      # subdirs in their listed (dependency) order.  Under `-j` that order isn't
      # enforced, so two races appear: (1) a TU compiles before the lib owning its
      # include/<hdr> forwarding header generated it -> gcc falls back to the glibc-hurd
      # sysroot's duplicate header -> divergent DWARF dir (the cross-host
      # libhurd-slab.a/slab.o drift); (2) a lib/prog links before a sibling lib's .so is
      # built -> undefined refs.  Both "worked" only because the listed order usually
      # wins the race.
      #
      # Fix: build the lib-subdirs in listed order, ONE AT A TIME (so each lib's deps +
      # forwarding headers exist before the next), but each lib builds with full `-j` -
      # the inter-lib races are strictly BETWEEN libs, while a lib's own objects are
      # independent and its .a/.so are assembled in fixed $(OBJS) order, so per-lib
      # parallelism is race-free and deterministic.  Then the default buildPhase builds
      # the prog-subdirs (the bulk) in PARALLEL.  Only the lib SUBDIRS are serialised
      # (they link each other); everything else is parallel.  lib-subdirs from make's db;
      # `|| true` keeps query-mode's nonzero exit from aborting under set -e/pipefail.
      preBuild = ''
        libs=$({ make -qp 2>/dev/null || true; } | sed -n 's/^lib-subdirs = //p' | head -1)
        [ -n "$libs" ] || { echo "preBuild: could not resolve lib-subdirs from make db" >&2; exit 1; }
        echo "hurd: serial library pass (dependency order, parallel within each) -> $libs"
        for d in $libs; do make $makeFlags -j''${NIX_BUILD_CORES:-1} -l''${NIX_BUILD_CORES:-1} "$d"; done
      '';

      # Parallel: the lib pass above built every library + its forwarding headers in
      # dependency order, so this pass builds the programs (the bulk) with no lib it
      # links and no header it includes missing.
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

      # Determinism + cleanliness come for free from the unwrapped cross-gcc - no
      # wrapper channels to fight:
      #  - DWARF determinism: the maps ride CPPFLAGS (set in preConfigure), mapping the
      #    out-of-tree $srcdir + $PWD to one canon root (hurdCanonBuild) + the gcc/binutils
      #    store paths.  The raw cc ignores NIX_CFLAGS_COMPILE, so no detCflagsExport.
      #  - No host -isystem leak: the cross-gcc resolves system headers ONLY from its
      #    --with-sysroot glibc (the old wrapped cc read the native stdenv's host
      #    -isystem, leaking darwin's libiconv into console/pc_kbd/vga; gone now).
      #  - No /nix/store DT_RUNPATH: the raw cross-binutils ld bakes no rpath, so the
      #    servers/libs resolve from /lib via the loader (Debian GNU/Hurd parity) with
      #    no NIX_LDFLAGS / NIX_DONT_SET_RPATH suppression needed.
    };
in
lib.mapAttrs' (name: target: lib.nameValuePair "hurd-${name}" (mkOne name target)) hurdTargets
