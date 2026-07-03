# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Own from-source cross GCC - built from the pinned `gcc-toolchain-src` release tarball on
# the NATIVE nixpkgs stdenv + `--target=<cpu>-gnu`, UNWRAPPED (no nix cc-wrapper),
# wired to our from-source cross-binutils (binutils.nix) via --with-as/--with-ld.
#
# Two compilers come out of the SAME src + a shared `mkGcc` base:
#
#   bootstrap (mkBootstrap)  the libc-free stage-1 cc: `--without-headers
#       --with-newlib`, C only, static libgcc.a, no shared/threads/extra runtime
#       libs.  Replaces nixpkgs' `gccWithoutTargetLibc`.  Compiles gnumach-headers /
#       mig / the glibc-hurd (glibc supplies its own headers; a no-libc gcc builds
#       glibc fine - the standard glibc bootstrap).
#
#   full (mkFull)  the FINAL cross compiler + the WHOLE target runtime in ONE
#       derivation: c+c++, bound to the (single) glibc-hurd via --with-sysroot, with
#       libgcc + libstdc++/libatomic/libitm/libquadmath/libssp/libgomp.  (gcc and its
#       runtime were going to be separate for cross-host CA dedup of the runtime libs;
#       CA is dropped project-wide, so they're merged - simpler, no -B wiring, and it
#       avoids the old split runtime's $out self-reference.)  UNWRAPPED: --with-sysroot
#       bakes the glibc sysroot so the cc finds crt/headers AND ld resolves the libc.so
#       `/lib` GROUP under the sysroot - replacing both the cc/bintools wrapper and the
#       bare-name glibc GROUP rewrite.  Called by packages.nix as `mkFull name target
#       <glibc-hurd drv>`.
#
# Determinism: the gcc BINARIES are build-host tools, never shipped (like binutils),
# so their host-varying bytes don't matter.  But libgcc.a/libgcc_s SHIP (link into
# glibc + every binary), so the target-lib build maps the host-varying roots out of
# their DWARF via CFLAGS_FOR_TARGET + CXXFLAGS_FOR_TARGET (see `targetMaps`).

{
  nixpkgs,
  system,
  targets,
  gcc-toolchain-src,
  ownBinutils,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  buildFlags = import ./build-flags.nix { inherit lib; };

  # gcc keeps its version in gcc/BASE-VER (e.g. "16.1.0") - parse it so a tarball
  # bump in flake.nix is the only edit needed (matches the binutils/glibc model).
  version = lib.removeSuffix "\n" (builtins.readFile (gcc-toolchain-src + "/gcc/BASE-VER"));

  # gcc 16's math/host prerequisites (the in-tree contrib/download_prerequisites
  # set) + zlib for LTO.  As buildInputs, stdenv exposes their include/lib so gcc's
  # configure auto-detects them - no need to thread --with-gmp/--with-mpc prefixes
  # through nixpkgs' split outputs.
  gccDeps = with pkgs; [
    gmp
    mpfr
    libmpc
    isl
    zlib
  ];

  # Mirrors nixpkgs' own gcc: the clang darwin host trips -Werror=format-security
  # on gcc's host sources, and -fstack-clash-protection must not apply to the
  # freestanding crt/libgcc.
  gccHardening = [
    "format"
    "stackclashprotection"
  ];

  # Non-xen userland targets only (i686, x86_64) - the xen variants share their CPU
  # sibling's toolchain (packages.nix resolves them via the crossTarget sibling).
  hurdTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;

  # Shared from-source cross-gcc builder.  build=host=native (stdenv adds
  # --build/--host + --prefix=$out); we add --target, the shared as/ld/zlib flags,
  # and the per-variant `extraConfigure`.  `glibcDrv` (full only) is the sysroot.
  mkGcc =
    {
      name,
      target,
      pname,
      desc,
      extraConfigure,
      buildList,
      installList,
      glibcDrv ? null,
      extraNativeBuildInputs ? [ ],
    }:
    let
      tp = target.crossTarget;
      binu = ownBinutils."cross-binutils-${name}";
      # SHIPPED target-lib (libgcc) determinism.  Map the host-varying roots out of
      # their DWARF: the build sandbox root ($NIX_BUILD_TOP - /build on linux, per-
      # build on darwin) always, and - for the full gcc - the glibc sysroot (IA, so
      # its store path is host-varying) since libgcc TUs include glibc headers.  A
      # make-arg (overrides configure's baked CFLAGS_FOR_TARGET); makeFlagsArray
      # expands $NIX_BUILD_TOP in the shell.
      targetMaps =
        "-ffile-prefix-map=$NIX_BUILD_TOP=${buildFlags.gccCanonRoot}"
        + lib.optionalString (
          glibcDrv != null
        ) " -ffile-prefix-map=${glibcDrv}=${buildFlags.glibcCanonSysroot}";
    in
    pkgs.stdenv.mkDerivation (
      {
        inherit pname version;
        src = gcc-toolchain-src;

        # Build the HOST compiler (cc1/cc1plus/lto1/lto-dump/the driver) WITHOUT debug
        # info (-O2, no -g; gcc's configure defaults to -g -O2).  These are build tools,
        # never shipped to the dist, and their DWARF bloats the toolchain + its cachix
        # closure by ~GB (cross-gcc 1.7G -> ~0.4G on linux; bootstrap-gcc 1.2G -> ~0.3G).
        # The TARGET runtime libs KEEP their -g via CFLAGS_FOR_TARGET/CXXFLAGS_FOR_TARGET
        # (preBuild) - so the dist-dbg tree still gets libgcc_s/libstdc++ debug and
        # bootstrap-gcc's libgcc.a stays -g (glibc byte-unchanged).  The compiler's own
        # debug never affects its codegen, so every target output (glibc, the runtime
        # libs, the whole dist) stays byte-identical - only host store paths shrink.
        CFLAGS = "-O2";
        CXXFLAGS = "-O2";

        nativeBuildInputs =
          (with pkgs; [
            perl
            gnumake
            texinfo
          ])
          ++ [ binu ]
          ++ buildFlags.commonNativeBuildInputs pkgs
          ++ extraNativeBuildInputs;
        buildInputs = gccDeps;
        hardeningDisable = gccHardening;

        # gcc strongly prefers an out-of-tree build dir; run configure from a sibling
        # `build/`.  Capture the src dir first so this is robust to how stdenv spells
        # $sourceRoot.  stdenv's configurePhase then runs $configureScript with its
        # auto --prefix/--build/--host appended.
        preConfigure = ''
          srcdir=$PWD
          mkdir -p ../build && cd ../build
          configureScript=$srcdir/configure
        '';

        configureFlags = [
          "--target=${tp}"
          "--with-as=${binu}/bin/${tp}-as"
          "--with-ld=${binu}/bin/${tp}-ld"
          "--with-system-zlib"
          "--disable-multilib"
          "--disable-bootstrap" # cross: no 3-stage self-build
        ]
        ++ extraConfigure;

        # The maps must reach BOTH the C and C++ target libs: libgcc/libatomic/libgomp/...
        # compile under CFLAGS_FOR_TARGET, but libstdc++/libsupc++/libitm under
        # CXXFLAGS_FOR_TARGET - set both, else the C++ libs leak the host-varying build /
        # glibc-sysroot paths into their DWARF and diverge cross-host.
        preBuild = ''
          makeFlagsArray+=("CFLAGS_FOR_TARGET=${buildFlags.baseCflags} ${targetMaps}")
          makeFlagsArray+=("CXXFLAGS_FOR_TARGET=${buildFlags.baseCflags} ${targetMaps}")
        '';

        # bootstrap trims to compiler + libgcc; full builds everything (all = compiler
        # + the whole target runtime).  The target-lib determinism (targetMaps) applies
        # to all of them via CFLAGS_FOR_TARGET + CXXFLAGS_FOR_TARGET (preBuild).
        buildFlags = buildList;
        installTargets = installList;

        passthru = { inherit target; };
        meta = with lib; {
          description = "${desc} for ${tp} (from-source pin)";
          platforms = platforms.all;
        };
      }
      // buildFlags.commonAttrs
    );

  mkBootstrap =
    name: target:
    mkGcc {
      inherit name target;
      pname = "bootstrap-gcc-${target.crossTarget}";
      desc = "Bootstrap (libc-free) cross GCC";
      buildList = [
        "all-gcc"
        "all-target-libgcc"
      ];
      installList = [
        "install-gcc"
        "install-target-libgcc"
      ];
      extraConfigure = [
        "--enable-languages=c"
        "--disable-nls" # throwaway bootstrap cc: no translated diagnostics needed
        "--without-headers" # no target libc headers yet
        "--with-newlib" # inhibit_libc: build libgcc with no target libc
        "--disable-shared"
        "--disable-threads"
        "--disable-decimal-float" # the full gcc enables the DFP runtime, not this
        "--disable-libgomp"
        "--disable-libquadmath"
        "--disable-libatomic"
        "--disable-libssp"
        "--disable-libstdcxx"
        "--disable-libvtv"
        "--disable-libsanitizer"
      ];
    };

  # The final compiler, bound to the glibc-hurd `glibcDrv` as its sysroot.
  #   --with-sysroot          glibc-hurd is the cross sysroot (crt/libs in /usr/lib,
  #                           libc.so /usr/lib GROUP resolved under it; /lib -> /usr/lib
  #                           compat symlink covers any bare /lib lookup).
  #   --with-native-system-header-dir=/usr/include   glibc-hurd is --prefix=/usr
  #                           (usr-merged; headers in usr/include - gcc's normal default).
  #   --enable-shared         shapes libgcc's baked link SPEC (-lgcc -lgcc_eh static /
  #                           -lgcc_s dynamic) to match the shipped runtime's layout.
  #   --enable-threads=posix  Hurd htl provides posix pthreads (glibc sysroot has
  #                           pthread.h) -> gthr-posix.
  mkFull =
    name: target: glibcDrv:
    mkGcc {
      inherit name target glibcDrv;
      pname = "cross-gcc-${target.crossTarget}";
      desc = "Cross GCC (glibc-bound, full runtime)";
      # MERGED compiler + full runtime: `all` builds libgcc + libstdc++/libatomic/
      # libitm/libquadmath/libssp/libgomp alongside the compiler.
      buildList = [ "all" ];
      installList = [ "install" ];
      # nls stays ON (gcc's default) for the shipped compiler; gettext supplies msgfmt
      # to build the message catalogs.
      extraNativeBuildInputs = [ pkgs.gettext ];
      extraConfigure = [
        "--enable-languages=c,c++"
        "--with-sysroot=${glibcDrv}"
        "--with-native-system-header-dir=/usr/include" # usr-merged glibc-hurd sysroot (gcc's normal default)
        "--enable-shared" # libtool default, but load-bearing: the shipped runtime must be shared
        "--enable-__cxa_atexit" # NOT a *-gnu default (config.gcc: no) - required for C++ static dtors
        # Dropped as redundant (verified in gcc-16 source): --enable-threads=posix
        # (config.gcc maps *-gnu -> thread_file=posix) and --enable-decimal-float
        # (config/dfp.m4 defaults i?86/x86_64-*-gnu to yes).
      ];
    };
in
{
  # bootstrap-gcc-<arch> : the from-source no-libc cc (the libc-free stage-1
  # compiler that builds gnumach-headers / mig / glibc-hurd).
  bootstrap = lib.mapAttrs' (
    name: target: lib.nameValuePair "bootstrap-gcc-${name}" (mkBootstrap name target)
  ) hurdTargets;

  # mkFull name target <glibc-hurd drv> -> the final cross-gcc-<arch>; packages.nix
  # threads the per-target glibc (so gcc.nix needs no glibc-attrset knowledge).
  inherit mkFull;
}
