# glibc-hurd — per-target Hurd C library derivation.
# (See .claude/docs/build/HURD-TOOLCHAIN-DESIGN.md for the overall plan.)
#
# Builds vanilla upstream glibc 2.43 from the pinned `glibc-src` flake
# input, configured for the Hurd target via `--host=<cpu>-gnu`.  glibc
# 2.43 has the htl (Hurd Threading Library) port built in — no separate
# `libpthread` add-on needed, unlike pre-2.40 configurations.
#
# Why a standalone derivation (not `nixpkgs.glibc.override`):
# nixpkgs' glibc package has many Linux-specific assumptions baked
# into its build expression (post-install hooks, linker-script
# rewrites, audit-libs propagation) plus a hard `meta.platforms =
# lib.platforms.linux` gate that refuses Hurd at evaluation time.
# Working around all of that would mean re-writing most of the
# nixpkgs derivation anyway; a fresh derivation against vanilla
# upstream glibc is cleaner, smaller, and easier to debug.  The
# trade-off is we re-implement the standard glibc build dance —
# but that dance is ~20 lines (out-of-tree build dir, configure with
# the cross-hurd flag set, make + make install).
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
# The combined sysroot include tree is built in preConfigure by
# symlink-farming gnumach-headers + hurd-headers into one directory —
# `--with-headers=$sysroot/include` then sees both as if they came
# from a unified GNU/Hurd installation.

{ nixpkgs, system, targets, mkCrossPkgs, mig, gnumachHeaders, hurdHeaders
, srcInput, forkUrl, deployPrefix ? false
  # Which cross-cc builds this glibc, as a `name: target: cc` function (the cc
  # is referenced by absolute path for CC=/CXX=, so pass a derivation whose
  # bin/<tp>-gcc + bin/<tp>-g++ exist).  Default = the libc-free stage-1 nolibc
  # cc (gccWithoutTargetLibc), used for the bootstrap glibc.  The reference and
  # working glibcs override this with the complete stage-2 / final gcc (Phase-2
  # 3-stage bootstrap — see PHASE-2-3STAGE-BOOTSTRAP.md).
, buildCC ? (name: target: (mkCrossPkgs system target).buildPackages.gccWithoutTargetLibc) }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };

  # glibc puts its version in version.h as `#define VERSION "2.43"`,
  # NOT in configure.ac (which says "(see version.h)") nor in a
  # version.m4.  Parse it directly with a regex match.
  upstreamVersion =
    let
      content = builtins.readFile (srcInput + "/version.h");
      m = builtins.match ".*define VERSION \"([0-9.]+)\".*" content;
    in
    if m == null then "unknown" else builtins.head m;

  fullVersion = helpers.composeToolchainVersion {
    inherit upstreamVersion srcInput forkUrl;
  };

  # Userland targets only (the non-xen ones — i686, x86_64).
  hurdTargets = lib.filterAttrs (name: target: (target.platform or null) != "xen") targets;

  mkOne = name: target:
    let
      crossPkgs       = mkCrossPkgs system target;
      # gccWithoutTargetLibc is a wrapper around the raw gcc; its
      # .cc attr is the raw cross-gcc derivation.  We reference both:
      # the wrapper for its bin/ (needed for absolute CC= paths) and
      # the raw cc/include for header search paths.  Crucially we do
      # NOT include the wrapper in buildInputs — its setup-hook
      # propagation would otherwise pull in binutils-wrapper, which
      # carries `libc_bin = glibc-i686-gnu-2.40-224` and trips
      # nixpkgs' `meta.platforms = lib.platforms.linux` gate on the
      # Hurd target.  Using paths only sidesteps the meta probe.
      crossCC         = buildCC name target;
      crossBinuRaw    = crossPkgs.buildPackages.binutils-unwrapped;
      crossMig        = mig."mig-${name}";
      gnumach-headers = gnumachHeaders."gnumach-headers-${name}";
      hurd-headers    = hurdHeaders."hurd-headers-${name}";
      pname           = "glibc-hurd-${target.crossTarget}";
      tp              = target.crossTarget;
    in
    # Use native (host) stdenv — glibc IS the cross libc, can't be
    # built by a cross-stdenv that requires libc to bootstrap.  Cross
    # tools come via explicit env vars in preConfigure (matches what
    # cross-hurd's bootstrap-funcs.sh does).
    pkgs.stdenv.mkDerivation ({
      inherit pname;
      version = fullVersion;
      src = srcInput;

      # rtld.c: walk _environ directly in process_envvars_secure,
      # otherwise the ld.so link fails with undefined `getenv` when
      # cross-building from a non-Linux host.  See the patch preamble.
      patches = [ ./patches/01-rtld-getenv-walk-environ.patch ];

      # glibc's build needs bison + perl + gawk + python + texinfo +
      # gettext at host side.  No autoreconf — glibc ships a working
      # configure in its git tree.  patchelf: glibc's Makerules runs
      # `patchelf --clear-execstack` on each installed .so at install time
      # (and probes `patchelf --version` first) — without it on PATH the
      # install logs "patchelf: command not found" for every library.  NOTE:
      # glibc gates the actual clear-execstack on patchelf >= 0.18.0; nixpkgs
      # ships 0.15.2, so this silences the probe but glibc still skips the
      # scrub until patchelf is overridden to >= 0.18.0.
      nativeBuildInputs = with pkgs; [
        bison perl gawk python3 texinfo gettext gnumake patchelf
      ];

      # buildInputs only carries derivations whose meta.platforms
      # allows the Hurd target — i.e. our own per-target outputs.
      # The cross-cc + cross-binutils are reached by absolute path
      # in configurePhase to avoid pulling the wrapped binutils
      # (which has a libc_bin dep on nixpkgs glibc → meta.platforms
      # gate trips on Hurd).
      buildInputs = [
        crossMig
        gnumach-headers
        hurd-headers
      ];

      # glibc REQUIRES an out-of-tree build dir — `configure` refuses
      # to run in the source dir.  Set up: combined sysroot include
      # tree (gnumach + hurd headers symlink-farmed) and the build
      # dir; export cross-toolchain tool names for glibc's configure
      # to pick up.
      configurePhase = ''
        runHook preConfigure

        # Combined headers sysroot — glibc's --with-headers wants ONE
        # path containing both Mach + Hurd .h files.  Using cp -rs
        # (symlink farm) keeps the closure size down vs cp -r.
        mkdir -p $TMPDIR/sysroot/include
        cp -rs ${gnumach-headers}/include/. $TMPDIR/sysroot/include/
        chmod -R u+w $TMPDIR/sysroot/include
        cp -rs ${hurd-headers}/include/.    $TMPDIR/sysroot/include/
        chmod -R u+w $TMPDIR/sysroot/include

        # Cross toolchain — glibc's configure honours these explicit
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

        # Configure.  Flag set verbatim from cross-hurd
        # bootstrap-funcs.sh compile_first_glibc, plus --disable-werror
        # (Guix carries the same) and --disable-multilib (cross hygiene).
        # --enable-add-ons=libpthread is harmless in 2.40+ (htl is
        # in-tree) and cross-hurd carries it; restored as belt-and-
        # braces.  libc_cv_ctors_header=yes is an autoconf-cache
        # override cross-hurd uses on the first pass — declares the
        # crt*.o ctor-section detection result rather than running a
        # link test (which would need a working libc to link).
        $src/configure \
          --build=${pkgs.stdenv.hostPlatform.config} \
          --host=${tp} \
          --prefix=${if deployPrefix then "/" else "$out"} \
          --with-headers=$TMPDIR/sysroot/include \
          --with-binutils=${crossBinuRaw}/bin \
          --enable-add-ons=libpthread \
          --enable-obsolete-rpc \
          --disable-profile \
          --disable-nscd \
          --disable-werror \
          --disable-multilib \
          libc_cv_ctors_header=yes${lib.optionalString deployPrefix " --libdir=/lib --sysconfdir=/etc --datarootdir=/share --localstatedir=/var --sbindir=/sbin --bindir=/bin --libexecdir=/libexec --includedir=/include libc_cv_slibdir=/lib libc_cv_rtlddir=/lib libc_cv_complocaledir=/lib/locale libc_cv_sysconfdir=/etc libc_cv_localstatedir=/var libc_cv_rootsbindir=/sbin"}

        runHook postConfigure
      '';

      # glibc's htl subdir emits both `stamp.os` and `stamp.oST` stamp
      # files, which collide on a case-insensitive filesystem — so the
      # nix store volume must be case-sensitive APFS (or any Linux fs).
      enableParallelBuilding = true;

      # Keep glibc's `-g` DWARF (don't let stdenv strip it).  The ABI gate
      # needs DWARF on both the working + reference glibc for abidiff/pahole;
      # carrying it natively means the gate analyses the real libraries
      # directly instead of building throwaway unstripped twins.  Stripping,
      # if ever wanted for a release artifact, is a dist-phase concern (no
      # dist-glibc exists today — glibc isn't a shipped artifact, only a
      # toolchain component).  See TOOLCHAIN-LIBC-DECOUPLING.md / task #197.
      dontStrip = true;

      # patchelf is in nativeBuildInputs for glibc's own Makerules
      # `--clear-execstack` step — but pulling it in also registers patchelf's
      # setup-hook, which adds a `patchelf --shrink-rpath` pass to fixupPhase.
      # We don't want that mutating a cross i686-gnu libc's .so RPATHs (output
      # stability), and observed it spams "shrinking …" / "wrong ELF type"
      # (the latter is patchelf refusing the crt*.o relocatables; harmless,
      # `|| true`d).  `dontPatchELF` guards ONLY that shrink hook — glibc's own
      # patchelf call is unaffected — so this keeps the binary available while
      # turning the shrink pass off.
      dontPatchELF = true;

      # Smoke-validate the deliverable: libc.so.0.3 (Hurd SONAME,
      # NOT libc.so.6) and the dynamic linker per arch.  Fails the
      # build early if the install layout is wrong.
      # glibc install-headers lays down glibc's own headers + the
      # mig-generated RPC stubs, but not the gnumach kernel headers or
      # the hurd headers (e.g. bits/sigcontext.h includes
      # mach/machine/fp_reg.h, which lives in gnumach-headers).  A
      # consumer that treats this output as the cross sysroot — gcc's
      # libcCross, the wrapped cc — needs the complete GNU/Hurd include
      # tree, so merge the gnumach + hurd headers in.  cp -an preserves
      # the mach/machine -> <arch> symlink and keeps glibc's own headers
      # on any overlap (glibc was built against these exact headers, so
      # there is no version skew).
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
        # __mach_port_*, __io_*, __proc_*, __file_* … which live in
        # libmachuser / libhurduser; without adding them to the GROUP,
        # every Hurd userland link fails on those undefined references.
        # (Same step as Guix's augment-libc.so.)  Restrict the sed to
        # the GROUP line so OUTPUT_FORMAT(...) — which also ends in ')'
        # — is untouched.
        sed -i "/^GROUP/ s|)\$|${if deployPrefix then " /lib/libmachuser.so /lib/libhurduser.so " else " $out/lib/libmachuser.so $out/lib/libhurduser.so "})|" \
          $out/lib/libc.so

        # i386: gcc's vanilla interpreter is /lib/ld.so (config/i386/gnu.h
        # GNU_USER_DYNAMIC_LINKER) but glibc names the loader ld.so.1, and
        # upstream installs no /lib/ld.so.  Add the bridge symlink — the same
        # packaging step Debian/Gentoo glibc do.  Self-gated on ld.so.1, so it's
        # a no-op on x86_64 (loader is ld-x86-64.so.1, which gcc emits directly).
        [ -e $out/lib/ld.so.1 ] && ln -sf ld.so.1 $out/lib/ld.so || true

        ls $out/lib/libc.so.0.3               || { echo "ERROR: libc.so.0.3 missing"; exit 1; }
        ls $out/include/stdio.h               || { echo "ERROR: stdio.h missing"; exit 1; }
        ls $out/include/mach/machine/fp_reg.h || { echo "ERROR: mach kernel headers not merged"; exit 1; }
        grep -q libmachuser $out/lib/libc.so  || { echo "ERROR: libc.so not augmented"; exit 1; }
      '';

      # Documents what this is, but glibc-hurd doesn't have a
      # meta.platforms restriction (it's only built for the non-xen
      # userland targets anyway).
      passthru = { inherit target; };
      meta = with lib; {
        description = "GNU C Library for ${tp} (Hurd port)";
        platforms = platforms.all;
        license = licenses.lgpl21Plus;
      };
    } // lib.optionalAttrs deployPrefix {
      installFlags = [ "DESTDIR=${placeholder "out"}" ];
      dontMoveSbin = true;
      # glibc's helper scripts (bin/{ldd,tzselect,xtrace,sotruss},
      # bin/mtrace) ship the portable shebang from their *.in source
      # (#!/bin/bash, #! /bin/sh) — glibc's ldd-rewrite sed never touches
      # line 1.  nixpkgs' patchShebangs fixup is what rewrites them to a
      # /nix/store bash, the lone store leak left in a deployed tree.  These
      # scripts run on the TARGET, not the build host, so disable the rewrite
      # and keep the /-rooted target shebang (fixed at build, no dist sed).
      dontPatchShebangs = true;
    });
in
lib.mapAttrs' (name: target: lib.nameValuePair "glibc-hurd-${name}" (mkOne name target)) hurdTargets
