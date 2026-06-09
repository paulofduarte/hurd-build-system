# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# The cross-gcc target RUNTIME, built from the prebuilt nolibc compiler against the
# WORKING glibc WITHOUT rebuilding cc1.  nixpkgs has no standalone runtime builder -
# it builds the runtime inside the full gcc (`make all-gcc all-target-libgcc`), and
# nothing that targets an already-built external libc - so this drives a partial gcc
# tree by hand: configure + emit libgcc's build glue (the host driver/gen-tools, never
# cc1), then compile each lib subdir with the prebuilt cc1 via GCC_FOR_TARGET.
#
#   mkCompiler  the single nolibc C++ compiler (cross-gcc-<arch>): cc1 + cc1plus +
#               static libgcc.a, no target libc.  Never rebuilt on a glibc hack.
#   mkRuntime   the runtime libs (cross-gcc-runtime-<arch>): libgcc (+ libstdc++/
#               libatomic/... added through the buildLib helper).

{ nixpkgs, mkCrossPkgs, wrappedToolchain }:

let
  lib        = nixpkgs.lib;
  buildFlags = import ./build-flags.nix { inherit lib; };

  # Mirrors nixpkgs' own gcc derivation (hardeningDisable = ["format" "stackclashprotection"]):
  # clang trips -Werror=format-security on gcc's host sources, and -fstack-clash-protection
  # mustn't apply to the freestanding crt/startup runtime.  Not importable (mkDerivation
  # folds it into NIX_HARDENING_ENABLE), so kept in sync by value.
  runtimeHardening = [ "format" "stackclashprotection" ];
in

{
  mkCompiler = system: target:
    (mkCrossPkgs system target).buildPackages.gccWithoutTargetLibc.cc.override {
      langCC = true;
    };

  mkRuntime = system: target: { compiler, working }:
    let
      bp      = (mkCrossPkgs system target).buildPackages;
      tgt     = target.crossTarget;
      # The prebuilt nolibc compiler wrapped around the working glibc: knows its
      # headers and links the bare-name libc.so GROUP (the same wrapper the in-tree
      # userland uses).  GCC_FOR_TARGET, so the libs compile with the prebuilt cc1.
      wrapped = wrappedToolchain system target { cc = compiler; working = working; };
    in
    bp.stdenv.mkDerivation ({
      pname   = "cross-gcc-runtime-${tgt}";
      version = compiler.version;
      src     = compiler.src;
      nativeBuildInputs = [ compiler bp.binutils-unwrapped bp.patchelf ];
      # gcc's top-level configure hard-requires GMP/MPFR/MPC even though we never build cc1.
      buildInputs = [ bp.gmp bp.mpfr bp.libmpc ];
      hardeningDisable = runtimeHardening;
      # Don't let darwin patchelf touch the cross ELFs (clear-execstack still runs in
      # the libs' own build); dontStrip rides commonAttrs.
      dontPatchELF = true;
      dontInstall  = true;   # buildLib installs each lib as it builds

      buildPhase = ''
        runHook preBuild
        gccdir=$PWD
        host=${tgt}
        build=${bp.stdenv.buildPlatform.config}
        cc="${wrapped}/bin/$host-gcc"
        cxx="${wrapped}/bin/$host-g++"

        mkdir -p ../b && cd ../b
        bdir=$PWD

        # DRY: configure + build + install one target-lib subdir, compiled with the
        # prebuilt cc1 (CC/CXX) against the working glibc.  Extra args ($@) are passed
        # to the subdir's configure (e.g. --enable-shared, a CFLAGS= override).
        buildLib() {
          local name=$1; shift
          mkdir -p "$bdir/$host/$name" && cd "$bdir/$host/$name"
          "$gccdir/$name/configure" \
            --host="$host" --build="$build" --prefix=/ --disable-multilib "$@" \
            CC="$cc" CXX="$cxx" AR="$host-ar" RANLIB="$host-ranlib" \
            AS="$host-as" LD="$host-ld" NM="$host-nm" STRIP="$host-strip"
          make -j"''${NIX_BUILD_CORES:-1}"
          make install DESTDIR="$out"
          cd "$bdir"
        }

        # The gcc tree + libgcc's build glue (host driver/gen-tools + libgcc.mvars/
        # tconfig.h, never cc1) - the base every lib needs.
        "$gccdir/configure" \
          --build="$build" --host="$build" --target="$host" \
          --prefix=/ --disable-bootstrap --disable-multilib \
          --enable-languages=c,c++ --with-sysroot=${working}
        make configure-gcc
        make all-build-libiberty all-build-libcpp \
             all-libiberty all-libcpp all-libdecnumber all-libbacktrace
        make -C gcc GCC_FOR_TARGET="$cc" tconfig.h libgcc.mvars
        mkdir -p gcc/include   # libgcc stages unwind.h here

        # libgcc first (everything else links libgcc_s); the rest go through buildLib.
        buildLib libgcc --enable-shared
        buildLib libatomic --enable-shared
        buildLib libssp --enable-shared
        buildLib libquadmath --enable-shared
        buildLib libitm --enable-shared
        buildLib libstdc++-v3 --enable-shared
        # libgomp: --disable-werror because affinity-fmt.c trips -Werror=discarded-
        # qualifiers against the Hurd glibc headers.  Build-enable only - OpenMP CPU
        # affinity on Hurd is incomplete.
        buildLib libgomp --enable-shared --disable-werror

        runHook postBuild
      '';
    } // buildFlags.commonAttrs);
}
