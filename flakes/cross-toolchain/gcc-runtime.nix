# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# cross-gcc + its split target RUNTIME.  cross-gcc (mkCompiler) is bootstrap-gcc rebuilt
# against the bootstrap glibc (libcCross - so nixpkgs gives it posix) but trimmed
# to compiler + static libgcc: it builds NO runtime.  mkRuntime then builds the WHOLE
# runtime (libgcc + the six libs) against the shipped glibc with cross-gcc, WITHOUT
# rebuilding cc1 - nixpkgs has no standalone runtime builder (it builds the runtime inside
# the full gcc), so this drives a partial gcc tree by hand: configure + emit libgcc's build
# glue (the host driver/gen-tools, never cc1), then compile each lib subdir with cross-gcc
# via GCC_FOR_TARGET.
#
#   mkCompiler  cross-gcc-<arch>: cc1 + cc1plus + static libgcc.a, bound to the bootstrap
#               glibc for its posix thread model.  Never rebuilt on an in-tree hack.
#   mkRuntime   cross-gcc-runtime-<arch>: libgcc + libstdc++/libatomic/libitm/libquadmath/
#               libssp/libgomp in ONE derivation against the shipped glibc, via buildLib.

{ nixpkgs, mkCrossPkgs, wrappedToolchain }:

let
  lib        = nixpkgs.lib;
  buildFlags = import ./build-flags.nix { inherit lib; };
  helpers    = import ../lib { inherit lib; };

  # Mirrors nixpkgs' own gcc derivation (hardeningDisable = ["format" "stackclashprotection"]):
  # clang trips -Werror=format-security on gcc's host sources, and -fstack-clash-protection
  # mustn't apply to the freestanding crt/startup runtime.  Not importable (mkDerivation
  # folds it into NIX_HARDENING_ENABLE), so kept in sync by value.
  runtimeHardening = [ "format" "stackclashprotection" ];

  # The ordered runtime lib set.  libgcc is FIRST: it has no -B (it IS libgcc),
  # and the rest -B the just-installed libgcc in $out (below).  Only libstdc++
  # diverges in srcDir: the gcc tree keeps the historical `libstdc++-v3`
  # directory name (the 1998 rewrite; no v4 ever - the ABI evolves in place),
  # but every user-facing name (the installed libstdc++.so) is plain libstdc++.
  # libgomp passes --disable-werror: its affinity-fmt.c trips
  # -Werror=discarded-qualifiers on the Hurd glibc headers.
  runtimeLibs = [
    { name = "libgcc";      srcDir = "libgcc";       flags = "--enable-shared"; }
    { name = "libstdc++";   srcDir = "libstdc++-v3"; flags = "--enable-shared"; }
    { name = "libatomic";   srcDir = "libatomic";    flags = "--enable-shared"; }
    { name = "libitm";      srcDir = "libitm";       flags = "--enable-shared"; }
    { name = "libquadmath"; srcDir = "libquadmath";  flags = "--enable-shared"; }
    { name = "libssp";      srcDir = "libssp";       flags = "--enable-shared"; }
    { name = "libgomp";     srcDir = "libgomp";      flags = "--enable-shared --disable-werror"; }
  ];
in

{
  # cross-gcc: the second-pass compiler.  bootstrap-gcc (nixpkgs gccWithoutTargetLibc)
  # rebuilt against the bootstrap glibc (libcCross) - that is what makes it posix
  # (the bootstrap glibc supplies pthread.h + htl) - but STOPPED at the compiler +
  # libgcc: no libstdc++/libatomic/...  cross-gcc-runtime owns every SHIPPED runtime lib,
  # built against the shipped glibc with this compiler; cross-gcc's own bootstrap-built
  # libgcc/libgcc_s exist only for the glibc bootstrap + the link spec, and the
  # wrapper's -B/-L always shadows them with the shipped runtime.  cross-gcc binds the
  # bootstrap glibc ONLY, so an in-tree hack never rebuilds it (a pin bump does).
  mkCompiler = system: target: refGlibc:
    let
      bp   = (mkCrossPkgs system target).buildPackages;
      salt = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] target.crossTarget;
      # withoutTargetLibc=false wires the target headers from libcCross (so libgcc finds
      # <stdio.h>/<pthread.h> and gthr-default.h comes out posix) - the bootstrap's
      # --without-headers path cannot.  enableShared MUST stay true: it shapes gcc's
      # baked libgcc link SPEC.  With shared off, the spec emits plain `-lgcc` (EH
      # assumed inside libgcc.a); the work runtime's libgcc is built shared, keeping EH
      # in libgcc_eh.a, so static links lose _Unwind_* (hurd's exec.static via glibc
      # backtrace.c).  Shared-on makes the spec emit `-lgcc -lgcc_eh` for static and
      # -lgcc_s for dynamic links - matching the runtime's layout.
      gcc = bp.gccWithoutTargetLibc.cc.override {
        withoutTargetLibc = false;
        langCC            = true;
        libcCross         = refGlibc;
      };
    in
    gcc.overrideAttrs (old: {
      configureFlags = (old.configureFlags or [ ]) ++ [
        # --with-ld: GNU cross ld so libtool's C++ --whole-archive probe resolves the same
        # on every host -> the libstdc++ cross-gcc-runtime builds is cross-host reproducible.
        "--with-ld=${bp.gccWithoutTargetLibc.bintools}/bin/${target.crossTarget}-ld"
        # decimal-float: libgcc's _Decimal* runtime.  nixpkgs already emits
        # --enable-{__cxa_atexit,long-long,nls,threads=posix} automatically for the full
        # cross gcc (withoutTargetLibc=false), but NOT this one, and the i686-gnu default
        # isn't guaranteed - so keep it explicit to ensure the DFP runtime is built.
        "--enable-decimal-float"
      ];
      # Stop at compiler + libgcc (incl. the bootstrap-built libgcc_s the shared spec needs at
      # its own build time).  The SHIPPED runtime (libstdc++/libatomic/... and the real
      # libgcc) comes from cross-gcc-runtime, so cross-gcc must not build the rest.
      buildFlags     = [ "all-gcc" "all-target-libgcc" ];
      installTargets = [ "install-gcc" "install-target-libgcc" ];
      # mechanism #2: the libgcc_s link binds the bootstrap glibc, whose --prefix=/ libc.so
      # GROUP lists absolute /lib members - resolvable only via --sysroot, which the nix
      # ld-wrapper strips from the command line.  Feed it through the salted env var the
      # wrapped --with-ld honours (same channel glibc.nix uses).
      env = (old.env or { }) // {
        "NIX_LDFLAGS_BEFORE${salt}" =
          ((old.env or { })."NIX_LDFLAGS_BEFORE${salt}" or "") + " --sysroot=${refGlibc}";
      };
    });

  # ONE cross-gcc-runtime-<arch> derivation: the partial gcc tree (host gen-tools
  # + libgcc.mvars/tconfig.h glue, never cc1) configured once, then libgcc and the
  # six libs built in sequence into a single $out.  Replaces the old rt-base +
  # per-lib split: with pin-stable glibc the runtime rebuilds only on full-rebuild
  # events, so bounding the FREQUENT rebuild to libgcc no longer earns its keep.
  # The toolchain -B's this whole tree (the per-lib `-B the libgcc drv` collapses
  # to `-B $out` here); the dist selects which libs to ship at COPY time.
  mkRuntime = system: target: { compiler, working }:
    let
      bp      = (mkCrossPkgs system target).buildPackages;
      tgt     = target.crossTarget;
      salt    = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] tgt;
      ver     = compiler.version;
      # No libgcc param: libgcc lives in this same $out, so the dependent libs
      # -B $out directly (added in buildPhase), not a separate derivation.
      wrapped = wrappedToolchain system target { cc = compiler; working = working; };
    in
    bp.stdenv.mkDerivation ({
      pname   = "cross-gcc-runtime-${tgt}";
      version = ver;
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

        # Partial gcc tree: top-level configure + host gen-tool libs + gcc/ glue
        # (libgcc.mvars/tconfig.h/include, never cc1).  --enable-threads=posix keeps
        # this runtime gcc-tree's gthr-default.h posix to match cross-gcc's.
        mkdir -p ../b && cd ../b
        bdir=$PWD
        "$gccdir/configure" \
          --build="$build" --host="$build" --target="$host" \
          --prefix=/ --disable-bootstrap --disable-multilib \
          --enable-languages=c,c++ --enable-threads=posix --with-sysroot=${working}
        make configure-gcc
        make all-build-libiberty all-build-libcpp \
             all-libiberty all-libcpp all-libdecnumber all-libbacktrace
        make -C gcc GCC_FOR_TARGET="$cc" tconfig.h libgcc.mvars
        mkdir -p gcc/include   # libgcc stages unwind.h here

        # Determinism: pin the host-varying inputs the reproducible-builds hook would
        # otherwise bake into the target libs - the cross-toolchain store paths (DWARF),
        # the build/src dirs, and -frandom-seed - so they come out cross-host identical.
        export NIX_CFLAGS_COMPILE${salt}="${buildFlags.debugPrefixMapStr wrapped} -ffile-prefix-map=$bdir=${buildFlags.gccRuntimeCanonBuild} -ffile-prefix-map=$gccdir=${buildFlags.gccRuntimeCanonSrc} -ffile-prefix-map=${working}=${buildFlags.gccRuntimeCanonSysroot} -frandom-seed=${buildFlags.randomSeed} ''${NIX_CFLAGS_COMPILE${salt}:-}"

        # --with-ld routes the link through gccWithoutTargetLibc's ld, which (unlike the
        # wrapped one) would bake a -rpath to the host-varying ${working}/lib.  Suppress
        # it (salted env var), so the libs carry no DT_RUNPATH (Debian Hurd parity).
        export NIX_DONT_SET_RPATH${salt}=1

        # configure + build + install one target-lib subdir.  $bflags (empty for
        # libgcc, then `-B$out/... -L$out/lib` for the dependents) makes the
        # dependent libs link the libgcc we just installed into $out - the
        # in-derivation replacement for the old per-lib `wrapper -B the libgcc drv`.
        # $out is the runtime's own (content-addressed) path, so the DWARF dir it
        # bakes is a self-reference - normalised by CA hashing, no canon-map needed.
        buildLib() {
          local name=$1; shift
          mkdir -p "$bdir/$host/$name" && cd "$bdir/$host/$name"
          "$gccdir/$name/configure" \
            --host="$host" --build="$build" --prefix=/ --disable-multilib "$@" \
            CC="$cc $bflags" CXX="$cxx $bflags" AR="$host-ar" RANLIB="$host-ranlib" \
            AS="$host-as" LD="$host-ld" NM="$host-nm" STRIP="$host-strip"
          make -j"''${NIX_BUILD_CORES:-1}"
          make install DESTDIR="$out"
          cd "$bdir"
        }

        # libgcc first (no -B), then the dependents -B the just-installed libgcc.
        bflags=""
        ${lib.concatMapStringsSep "\n        " (l:
          ''buildLib ${l.srcDir} ${l.flags}''
          + lib.optionalString (l.name == "libgcc")
              ''; bflags="-B$out/lib/gcc/$host/${ver} -L$out/lib"''
        ) runtimeLibs}

        runHook postBuild
      '';
      # Content-addressed: a content-identical glibc rebuild stops here instead of
      # rippling into the dist copies and future consumers.  Reproducible (ships
      # only the installed libs, not the old rt-base build tree), so CA is sound.
    } // buildFlags.commonAttrs // helpers.mkCaAttrs true);
}
