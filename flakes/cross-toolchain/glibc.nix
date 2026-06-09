# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# glibc-hurd - per-target Hurd C library derivation.
# (See .claude/docs/build/HURD-TOOLCHAIN-DESIGN.md for the overall plan.)
#
# Builds vanilla upstream glibc 2.43 from the pinned `glibc-src` flake input,
# configured for the Hurd target via `--host=<cpu>-gnu`.  glibc 2.43 has the htl
# (Hurd Threading Library) port built in - no separate `libpthread` add-on.
#
# A standalone derivation (not `nixpkgs.glibc.override`): nixpkgs' glibc bakes in
# Linux-specific assumptions (post-install hooks, linker-script rewrites, audit-
# libs propagation) plus a hard `meta.platforms = lib.platforms.linux` gate that
# refuses Hurd at eval time.  Working around all of it means rewriting most of the
# derivation anyway; a fresh one against vanilla glibc is cleaner - the standard
# build dance is ~20 lines (out-of-tree build dir, configure, make + make install).
#
# Outputs:
#   $out/lib/libc.so.0.3                 the Hurd libc SONAME
#                                        (vs Linux's libc.so.6)
#   $out/lib/libpthread.so.0.3           Hurd pthread
#   $out/lib/ld.so.1 (i686) /            dynamic linker, per-arch
#     ld-x86-64.so.1 (x86_64)
#   $out/lib/{crt1.o,crti.o,crtn.o}      C runtime startup objects
#   $out/include/{stdio.h,stdlib.h,...}  the full glibc header tree
#   $out/include/hurd/, mach/             headers propagated from
#                                        hurd-headers + gnumach-headers
#
# Toolchain inputs come from the existing flake outputs:
#   stage-1 gcc + cross-binutils      flakes/cross-toolchain (mkCrossPkgs)
#   gnumach-headers + hurd-headers    sibling flakes
#   mig                               sibling flake
#
# The combined sysroot include tree is built in preConfigure by symlink-farming
# gnumach-headers + hurd-headers into one directory, so
# `--with-headers=$sysroot/include` sees both as one GNU/Hurd installation.

{ nixpkgs, system, targets, mkCrossPkgs, mig, gnumachHeaders, hurdHeaders
, srcInput, forkUrl
  # Which cross-cc builds this glibc, as a `name: target: cc` function (the cc is
  # referenced by absolute path for CC=/CXX=, so pass a derivation with bin/<tp>-gcc
  # + bin/<tp>-g++).  Default = the libc-free nolibc stage-1 cc, used by the
  # reference glibc; the working glibc overrides it with the final ref-wrapped gcc.
, buildCC ? (name: target: (mkCrossPkgs system target).buildPackages.gccWithoutTargetLibc) }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };
  # Shared cross-build determinism flags (the SAME source the dev-shell +
  # gnumach/hurd use), fed through NIX_CFLAGS_COMPILE below so the nix glibc comes
  # out byte-identical cross-host, like the in-tree build.
  buildFlags = import ./build-flags.nix { inherit lib; };
  glibcConfig = import ./glibc-config.nix;
  toolchainPaths = import ./toolchain-paths.nix { inherit nixpkgs mkCrossPkgs; };

  # Patched (deterministic) install-info - the SAME one the dev-shell uses
  # (texinfo-det.nix).  glibc's `make install` runs install-info to build
  # share/info/dir; the unpatched upstream comparator is host-dependent + writes a
  # different default header, so the shipped dir diverges.  The patch makes it
  # identical and reproducible.
  texinfoDet = import ./texinfo-det.nix { inherit pkgs; };

  # glibc's version lives in version.h as `#define VERSION "2.43"`, not in
  # configure.ac or a version.m4 - parse it with a regex match.
  upstreamVersion =
    let
      content = builtins.readFile (srcInput + "/version.h");
      m = builtins.match ".*define VERSION \"([0-9.]+)\".*" content;
    in
    if m == null then "unknown" else builtins.head m;

  fullVersion = helpers.composeToolchainVersion {
    inherit upstreamVersion srcInput forkUrl;
  };

  # Userland targets only (the non-xen ones - i686, x86_64).
  hurdTargets = lib.filterAttrs (name: target: (target.platform or null) != "xen") targets;

  mkOne = name: target:
    let
      crossPkgs       = mkCrossPkgs system target;
      # crossCC is reached by absolute path only - NOT a buildInput.  As a
      # buildInput its setup-hook would pull in binutils-wrapper (which carries a
      # `libc_bin` glibc dep) and trip nixpkgs' `meta.platforms = lib.platforms.
      # linux` gate on the Hurd target.  Paths-only sidesteps the meta probe.
      crossCC         = buildCC name target;
      tcPaths         = toolchainPaths system target;
      crossBinuRaw    = tcPaths.binutils;
      crossMig        = mig."mig-${name}";
      gnumach-headers = gnumachHeaders."gnumach-headers-${name}";
      hurd-headers    = hurdHeaders."hurd-headers-${name}";
      pname           = "glibc-hurd-${target.crossTarget}";
      tp              = target.crossTarget;
      # The cc-wrapper suffix salt (NIX_*_<salt>), matching wrapCCWith's.
      salt            = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] tp;
    in
    # Native (host) stdenv - glibc IS the cross libc, can't be built by a
    # cross-stdenv that requires libc to bootstrap.  Cross tools come via explicit
    # env vars in preConfigure (matches cross-hurd's bootstrap-funcs.sh).
    pkgs.stdenv.mkDerivation ({
      inherit pname;
      version = fullVersion;
      src = srcInput;

      # rtld.c: walk _environ directly in process_envvars_secure, else the ld.so
      # link fails with undefined `getenv` when cross-building from a non-Linux
      # host.  See the patch preamble.
      patches = [ ./patches/01-rtld-getenv-walk-environ.patch ];

      # Host-side build tools.  No autoreconf - glibc ships a working configure.
      # patchelf: glibc's Makerules probes `patchelf --version` + runs
      # `--clear-execstack` per installed .so; without it on PATH the install logs
      # "patchelf: command not found".  NOTE: glibc gates the actual scrub on
      # patchelf >= 0.18.0 and nixpkgs ships 0.15.2, so this silences the probe but
      # the scrub still skips until patchelf is overridden to >= 0.18.0.
      nativeBuildInputs = (with pkgs; [
        bison perl gawk python3 gettext gnumake patchelf
      ]) ++ [ texinfoDet ];

      # buildInputs only carries derivations whose meta.platforms allows the Hurd
      # target (our own per-target outputs).  The cross-cc + cross-binutils are
      # reached by absolute path in configurePhase to dodge the wrapped binutils'
      # libc_bin dep -> meta.platforms gate.
      buildInputs = [
        crossMig
        gnumach-headers
        hurd-headers
      ];

      # glibc REQUIRES an out-of-tree build dir.  Sets up the combined sysroot
      # include tree (gnumach + hurd headers symlink-farmed) and the build dir,
      # and exports the cross-toolchain tool names for glibc's configure.
      configurePhase = ''
        runHook preConfigure

        # Combined headers sysroot - glibc's --with-headers wants ONE
        # path containing both Mach + Hurd .h files.  Using cp -rs
        # (symlink farm) keeps the closure size down vs cp -r.
        mkdir -p $TMPDIR/sysroot/include
        cp -rs ${gnumach-headers}/include/. $TMPDIR/sysroot/include/
        chmod -R u+w $TMPDIR/sysroot/include
        cp -rs ${hurd-headers}/include/.    $TMPDIR/sysroot/include/
        chmod -R u+w $TMPDIR/sysroot/include

        # Cross toolchain - glibc's configure honours these explicit
        # env vars (matches cross-hurd's bootstrap-funcs.sh).  Use the
        # wrapped cc so cc-wrapper handles sysroot / -isystem search;
        # tools come from the unwrapped binutils so their paths are
        # absolute.
        export BUILD_CC=${pkgs.stdenv.cc}/bin/cc
        export CC=${crossCC}/bin/${tp}-gcc
        export CXX=${crossCC}/bin/${tp}-g++
        export AR=${crossBinuRaw}/bin/${tp}-ar
        export AS=${crossBinuRaw}/bin/${tp}-as
        export LD=${crossBinuRaw}/bin/${tp}-ld
        export NM=${crossBinuRaw}/bin/${tp}-nm
        export OBJCOPY=${crossBinuRaw}/bin/${tp}-objcopy
        export OBJDUMP=${crossBinuRaw}/bin/${tp}-objdump
        export RANLIB=${crossBinuRaw}/bin/${tp}-ranlib
        export READELF=${crossBinuRaw}/bin/${tp}-readelf
        export STRIP=${crossBinuRaw}/bin/${tp}-strip

        # Out-of-tree build dir.  glibc's configure aborts hard if
        # invoked from $srcdir.
        mkdir -p build
        cd build

        # Cross-host + in-tree==nix determinism (build-flags.nix - the same canon
        # names the dev-shell + the in-tree Makefile use): map every host-varying /
        # build-method-specific root out of glibc's DWARF so the result is identical
        # in any combination of {darwin,linux} x {in-tree,nix}:
        #   ${buildFlags.glibcCanonSrc} <- $src (this build's source root)
        #   ${buildFlags.glibcCanonBuild} <- $PWD (this build dir - nix's is a SANDBOX
        #     temp, host-varying, so this is load-bearing for nix cross-host)
        #   ${buildFlags.glibcCanonSysroot} <- $TMPDIR/sysroot (the combined headers;
        #     also a host-varying sandbox temp) + /cross-* (toolchain via build-flags).
        #
        # MUST set the SUFFIX-SALTED var (NIX_CFLAGS_COMPILE${salt}), not the plain
        # one: the cc-wrapper only folds plain NIX_CFLAGS_COMPILE into the salted var
        # it reads at invocation via its SETUP-HOOK (mangleVarList) - and crossCC is
        # used by ABSOLUTE PATH here (never a buildInput; its meta.platforms gate
        # would trip on Hurd), so that hook never runs.  ${tp}-gcc reads
        # NIX_CFLAGS_COMPILE${salt} directly, so feed it there.  (The reproducible-
        # builds $out -frandom-seed lands in the NATIVE salt and never reaches the
        # cross cc, so there is nothing to strip; we still pin the seed for parity.)
        # ORDER matters: gcc's -ffile-prefix-map is LAST-match-wins, so the specific
        # "$PWD/hurd/." (collapses the Machrules `./` vpath that makes libhurduser's
        # DWARF build-order-dependent - `$(objpfx)./`) must come AFTER the general
        # "$PWD" build-dir map, else the general one overrides it and the `./` stays.
        # Keep it the very last map so nothing (incl. the inherited var) overrides it.
        export NIX_CFLAGS_COMPILE${salt}="${buildFlags.debugPrefixMapStr crossCC} -ffile-prefix-map=$PWD=${buildFlags.glibcCanonBuild} -ffile-prefix-map=$src=${buildFlags.glibcCanonSrc} -ffile-prefix-map=$TMPDIR/sysroot=${buildFlags.glibcCanonSysroot} -frandom-seed=${buildFlags.randomSeed} ''${NIX_CFLAGS_COMPILE${salt}:-} -ffile-prefix-map=$PWD/hurd/.=${buildFlags.glibcCanonBuild}/hurd"

        # Configure.  Flag set verbatim from cross-hurd
        # bootstrap-funcs.sh compile_first_glibc, plus --disable-werror
        # (Guix carries the same) and --disable-multilib (cross hygiene).
        # --enable-add-ons=libpthread is harmless in 2.40+ (htl is
        # in-tree) and cross-hurd carries it; restored as belt-and-
        # braces.  libc_cv_ctors_header=yes is an autoconf-cache
        # override cross-hurd uses on the first pass - declares the
        # crt*.o ctor-section detection result rather than running a
        # link test (which would need a working libc to link).
        $src/configure \
          --build=${tcPaths.buildTriple} \
          --host=${tcPaths.hostTriple} \
          --prefix=/ \
          --with-headers=$TMPDIR/sysroot/include \
          --with-binutils=${tcPaths.binutilsBin} \
          ${lib.concatStringsSep " " glibcConfig.coreFlags} ${lib.concatStringsSep " " glibcConfig.deployFlags}

        runHook postConfigure
      '';

      # glibc's htl subdir emits both `stamp.os` and `stamp.oST`, which collide on
      # a case-insensitive filesystem - so the nix store volume must be case-
      # sensitive APFS (or any Linux fs).
      enableParallelBuilding = true;

      # Keep glibc's `-g` DWARF (don't let stdenv strip it): the ABI gate needs
      # DWARF on both the working + reference glibc for abidiff/pahole, so it
      # analyses the real libraries directly instead of unstripped twins.
      # Stripping for a release artifact is a dist-phase concern (no dist-glibc
      # today - glibc is a toolchain component, not a shipped artifact).
      # See TOOLCHAIN-LIBC-DECOUPLING.md / task #197.
      dontStrip = true;

      # patchelf is in nativeBuildInputs for glibc's own `--clear-execstack` step,
      # but pulling it in also registers patchelf's `--shrink-rpath` setup-hook.
      # We don't want that mutating the cross libc's .so RPATHs (output stability),
      # and it spams "shrinking ..." / "wrong ELF type" (patchelf refusing the crt*.o
      # relocatables; harmless).  `dontPatchELF` guards ONLY that shrink hook -
      # glibc's own patchelf call is unaffected.
      dontPatchELF = true;

      # Smoke-validate the deliverable: libc.so.0.3 (Hurd SONAME, NOT libc.so.6) +
      # the per-arch dynamic linker; fails early on a wrong install layout.
      # glibc install-headers lays down glibc's own headers + the mig RPC stubs,
      # but not the gnumach/hurd headers (e.g. bits/sigcontext.h includes
      # mach/machine/fp_reg.h from gnumach-headers).  A consumer treating this as
      # the cross sysroot (gcc's libcCross, the wrapped cc) needs the complete
      # GNU/Hurd include tree, so merge them in.  cp -an preserves the
      # mach/machine -> <arch> symlink and keeps glibc's own headers on overlap
      # (built against these exact headers - no version skew).
      postInstall = ''
        # Merge in the gnumach + hurd headers (cp -a preserves the
        # mach/machine -> <arch> symlink; -n keeps glibc's own on any
        # overlap).  chmod between copies because each cp finalises the
        # dirs it creates read-only, which would block the next one.
        chmod -R u+w $out/include
        cp -an ${gnumach-headers}/include/. $out/include/ ; chmod -R u+w $out/include
        cp -an ${hurd-headers}/include/.    $out/include/ ; chmod -R u+w $out/include

        # Augment the libc.so linker script so `-lc` also pulls the Mach
        # + Hurd RPC stub libraries.  libc.so.0.3 has undefined refs to
        # __mach_port_*, __io_*, __proc_*, __file_* ... which live in
        # libmachuser / libhurduser; without adding them to the GROUP,
        # every Hurd userland link fails on those undefined references.
        # (Same step as Guix's augment-libc.so.)  Restrict the sed to
        # the GROUP line so OUTPUT_FORMAT(...) - which also ends in ')'
        # - is untouched.
        sed -i "/^GROUP/ s|)\$| /lib/libmachuser.so /lib/libhurduser.so )|" \
          $out/lib/libc.so

        # i386: gcc's vanilla interpreter is /lib/ld.so (config/i386/gnu.h
        # GNU_USER_DYNAMIC_LINKER) but glibc names the loader ld.so.1, and
        # upstream installs no /lib/ld.so.  Add the bridge symlink - the same
        # packaging step Debian/Gentoo glibc do.  Self-gated on ld.so.1, so it's
        # a no-op on x86_64 (loader is ld-x86-64.so.1, which gcc emits directly).
        [ -e $out/lib/ld.so.1 ] && ln -sf ld.so.1 $out/lib/ld.so || true

        ls $out/lib/libc.so.0.3               || { echo "ERROR: libc.so.0.3 missing"; exit 1; }
        ls $out/include/stdio.h               || { echo "ERROR: stdio.h missing"; exit 1; }
        ls $out/include/mach/machine/fp_reg.h || { echo "ERROR: mach kernel headers not merged"; exit 1; }
        grep -q libmachuser $out/lib/libc.so  || { echo "ERROR: libc.so not augmented"; exit 1; }
      '';

      # No meta.platforms restriction - only built for the non-xen userland targets
      # anyway.
      passthru = { inherit target; };
      meta = with lib; {
        description = "GNU C Library for ${tp} (Hurd port)";
        platforms = platforms.all;
        license = licenses.lgpl21Plus;
      };
    } // {
      installFlags = [ "DESTDIR=${placeholder "out"}" ];
      dontMoveSbin = true;
      # No /nix/store DT_RUNPATH on the shipped sub-libraries.  glibc links
      # libmachuser/libhurduser/libpthread (and the nss/rt/resolv/... stubs) against
      # the prior (reference) glibc via the wrapper's `-L<refglibc>/lib`, and the
      # nix ld-wrapper auto-derives a DT_RUNPATH to that store dir - a leak in a
      # --prefix=/ tree (the libs resolve libc.so.0.3 from /lib via the loader
      # path).  libc.so.0.3 / ld.so escape (linked -nostdlib).  glibc.nix uses the
      # cc by ABSOLUTE PATH (to dodge the meta gate), so no wrapper setup-hook runs
      # and gcc's --with-ld bintools carries no suppression - set the real env var
      # here (same channel mkGcc uses for libgcc_s/libstdc++).
      "NIX_DONT_SET_RPATH${salt}" = "1";
      # glibc's helper scripts (bin/{ldd,tzselect,xtrace,sotruss,mtrace}) ship a
      # portable shebang from their *.in source; nixpkgs' patchShebangs rewrites it
      # to a /nix/store bash, the lone store leak left in a deployed tree.  These
      # scripts run on the TARGET, so disable the rewrite and keep the /-rooted
      # shebang (fixed at build, no dist sed).
      dontPatchShebangs = true;
    });
in
lib.mapAttrs' (name: target: lib.nameValuePair "glibc-hurd-${name}" (mkOne name target)) hurdTargets
