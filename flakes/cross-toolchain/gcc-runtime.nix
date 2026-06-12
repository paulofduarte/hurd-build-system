# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# cross-gcc + its split target RUNTIME.  cross-gcc (mkCompiler) is bootstrap-gcc rebuilt
# against the pinned REFERENCE glibc (libcCross - so nixpkgs gives it posix) but trimmed
# to compiler + static libgcc: it builds NO runtime.  mkRuntimeLib then builds ONE runtime
# lib against the WORKING glibc with cross-gcc, WITHOUT rebuilding cc1 - nixpkgs has no
# standalone runtime builder (it builds the runtime inside the full gcc), so this drives a
# partial gcc tree by hand: configure + emit libgcc's build glue (the host driver/gen-tools,
# never cc1), then compile the lib subdir with cross-gcc via GCC_FOR_TARGET.
#
#   mkCompiler    cross-gcc-<arch>: cc1 + cc1plus + static libgcc.a, bound to the ref glibc
#                 for its posix thread model.  Never rebuilt on a WORKING-glibc hack.
#   mkRuntimeLib  cross-gcc-rt-<lib>-<arch>: one target-runtime lib (libgcc standalone; the
#                 rest -B the libgcc derivation) against the WORKING glibc, via buildLib.

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
  # cross-gcc: the second-pass compiler.  bootstrap-gcc (nixpkgs gccWithoutTargetLibc)
  # rebuilt against the PINNED reference glibc (libcCross) - that is what makes it posix
  # (the ref glibc supplies pthread.h + htl) - but STOPPED at the compiler + libgcc: no
  # libstdc++/libatomic/...  cross-gcc-rt-* owns every SHIPPED runtime lib, built against
  # the WORKING glibc with this compiler; cross-gcc's own ref-built libgcc/libgcc_s exist
  # only for the glibc bootstrap + the link spec, and the wrapper's -B/-L always shadows
  # them with the work-built runtime.  cross-gcc binds the ref ONLY, so a working-glibc
  # hack never rebuilds it (a ref bump does).
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
      # Stop at compiler + libgcc (incl. the ref-built libgcc_s the shared spec needs at
      # its own build time).  The SHIPPED runtime (libstdc++/libatomic/... and the real
      # libgcc) comes from cross-gcc-rt-*, so cross-gcc must not build the rest.
      buildFlags     = [ "all-gcc" "all-target-libgcc" ];
      installTargets = [ "install-gcc" "install-target-libgcc" ];
      # mechanism #2: the libgcc_s link binds the ref glibc, whose --prefix=/ libc.so
      # GROUP lists absolute /lib members - resolvable only via --sysroot, which the nix
      # ld-wrapper strips from the command line.  Feed it through the salted env var the
      # wrapped --with-ld honours (same channel glibc.nix uses).
      env = (old.env or { }) // {
        "NIX_LDFLAGS_BEFORE${salt}" =
          ((old.env or { })."NIX_LDFLAGS_BEFORE${salt}" or "") + " --sysroot=${refGlibc}";
      };
    });

  # The shared runtime-build base: the partial gcc tree every cross-gcc-rt-<lib>
  # needs - top-level configure + the host gen-tool libs + gcc/{libgcc.mvars,
  # tconfig.h,include/} (never cc1) - built ONCE and shipped as a tree the per-lib
  # derivations copy into their own sandbox.  Safe to relocate: the lib subdir
  # builds reference the base only via RELATIVE paths (libgcc's Makefile includes
  # $(gcc_objdir)/libgcc.mvars as ../../gcc/ from $bdir/$host/libgcc), and nothing
  # re-invokes the top-level make (whose baked sandbox paths die with this sandbox).
  mkRuntimeBase = system: target: { compiler, working }:
    let
      bp      = (mkCrossPkgs system target).buildPackages;
      tgt     = target.crossTarget;
      wrapped = wrappedToolchain system target { cc = compiler; working = working; };
    in
    bp.stdenv.mkDerivation ({
      pname   = "cross-gcc-rt-base-${tgt}";
      version = compiler.version;
      src     = compiler.src;
      nativeBuildInputs = [ compiler bp.binutils-unwrapped ];
      # gcc's top-level configure hard-requires GMP/MPFR/MPC even though we never build cc1.
      buildInputs = [ bp.gmp bp.mpfr bp.libmpc ];
      hardeningDisable = runtimeHardening;
      dontPatchELF = true;
      dontFixup    = true;   # build-tree intermediate; nothing here ships

      buildPhase = ''
        runHook preBuild
        gccdir=$PWD
        host=${tgt}
        build=${bp.stdenv.buildPlatform.config}
        cc="${wrapped}/bin/$host-gcc"

        mkdir -p ../b && cd ../b

        # The gcc tree + libgcc's build glue (host driver/gen-tools + libgcc.mvars/
        # tconfig.h, never cc1) - the base every lib needs.  --enable-threads=posix keeps
        # this runtime gcc-tree's gthr-default.h posix to match cross-gcc's (belt-and-
        # braces for libgcc's in-tree build; the libs otherwise take cross-gcc's via the
        # wrapped GCC_FOR_TARGET).
        "$gccdir/configure" \
          --build="$build" --host="$build" --target="$host" \
          --prefix=/ --disable-bootstrap --disable-multilib \
          --enable-languages=c,c++ --enable-threads=posix --with-sysroot=${working}
        make configure-gcc
        make all-build-libiberty all-build-libcpp \
             all-libiberty all-libcpp all-libdecnumber all-libbacktrace
        make -C gcc GCC_FOR_TARGET="$cc" tconfig.h libgcc.mvars
        mkdir -p gcc/include   # libgcc stages unwind.h here

        mkdir -p $out
        cp -a . $out/build
        runHook postBuild
      '';
      dontInstall = true;
    } // buildFlags.commonAttrs);

  # Build ONE target-runtime lib as its own derivation: copy the shared `base` tree
  # into the sandbox, then buildLib for this lib.  libgcc is standalone; the rest
  # pass `libgccDrv` (the already-built libgcc derivation) so the wrapper -B's it and
  # they link the WORK-built libgcc (GCC_FOR_TARGET).  Splitting per-lib lets the
  # toolchain depend on libgcc alone (not a 7-lib monolith) and the rest build on demand.
  mkRuntimeLib = system: target: { compiler, working, base, libName, extraFlags ? "--enable-shared", libgccDrv ? null }:
    let
      bp      = (mkCrossPkgs system target).buildPackages;
      tgt     = target.crossTarget;
      salt    = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] tgt;
      # gcc's source subdir for the lib.  Only libstdc++ diverges: the gcc tree keeps
      # the historical `libstdc++-v3` directory name (the 1998 rewrite; there is no v4
      # and never will be - the ABI evolves in place), but every user-facing name
      # (attr, target, the installed libstdc++.so) is plain libstdc++.
      srcDir  = if libName == "libstdc++" then "libstdc++-v3" else libName;
      # cross-gcc wrapped around the working glibc; for the non-libgcc libs the wrapper
      # also -B's the libgcc derivation so they link the WORK-built libgcc.
      wrapped = wrappedToolchain system target { cc = compiler; working = working; libgcc = libgccDrv; };
    in
    bp.stdenv.mkDerivation ({
      pname   = "cross-gcc-rt-${libName}-${tgt}";
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

        # The shared base tree (configured top-level + host gen-tools + gcc/ glue),
        # copied into this sandbox so the lib subdir's relative ../../gcc references
        # resolve.  Store perms are read-only; the lib build writes beside them.
        mkdir -p ../b && cd ../b
        bdir=$PWD
        cp -a ${base}/build/. "$bdir"/
        chmod -R u+w "$bdir"

        # Determinism: pin the host-varying inputs the reproducible-builds hook would
        # otherwise bake into the target libs - the cross-toolchain store paths (DWARF),
        # the build/src dirs, and -frandom-seed - so they come out cross-host identical.
        export NIX_CFLAGS_COMPILE${salt}="${buildFlags.debugPrefixMapStr wrapped} -ffile-prefix-map=$bdir=${buildFlags.gccRuntimeCanonBuild} -ffile-prefix-map=$gccdir=${buildFlags.gccRuntimeCanonSrc} -ffile-prefix-map=${working}=${buildFlags.gccRuntimeCanonSysroot} -frandom-seed=${buildFlags.randomSeed} ''${NIX_CFLAGS_COMPILE${salt}:-}"

        # --with-ld routes the link through gccWithoutTargetLibc's ld, which (unlike the
        # wrapped one) would bake a -rpath to the host-varying ${working}/lib.  Suppress
        # it (salted env var), so the libs carry no DT_RUNPATH (Debian Hurd parity).
        export NIX_DONT_SET_RPATH${salt}=1

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

        # Build the one requested lib.  libgcc has no -B (it IS libgcc); the rest link
        # the libgcc derivation via the wrapper's -B.  (libgomp passes --disable-werror -
        # its affinity-fmt.c trips -Werror=discarded-qualifiers on the Hurd glibc headers.)
        buildLib ${srcDir} ${extraFlags}

        runHook postBuild
      '';
    } // buildFlags.commonAttrs);
}
