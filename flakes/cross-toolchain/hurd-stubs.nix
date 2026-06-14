# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# hurd-stubs - the extracted Mach/Hurd RPC stub libraries (libmachuser.so.1 +
# libhurduser.so.0.3), split OUT of glibc so an in-tree RPC change rebuilds just
# the stubs (~30 s) instead of the whole glibc (~100 s VM).
#
# Mechanism (the rt-base pattern applied to glibc): glibc-stub-base ships a full
# glibc BUILD TREE (glibc.nix buildTree mode); this derivation copies it, points
# the sysroot at the (overridable) ALIAS gnumach/hurd headers, force-rebuilds the
# mach/ + hurd/ subdir stub targets with the ALIAS mig, and extracts the libs.
# The stubs link against the base tree's own libc.so/csu/htl (glibc's -z defs
# link needs them) - so the rebuild reuses glibc's exact rules.
#
# Correctness: with NO in-tree override the alias headers/mig ARE the pin
# headers/mig (the follows-alias dedups to the same nix input the base used), so
# nix guarantees the stubs match what glibc would build - nothing to check.  An
# in-tree override floats the stubs with the working RPC surface; the glibc<->
# kernel skew that introduces is caught by the header-drift gate (design doc
# phase 5).  Cross-host reproducibility is via this derivation's OWN canon maps
# (it need not byte-match glibc's in-tree stubs).

{ nixpkgs, system, targets, mkCrossPkgs, mig, gnumachHeaders, hurdHeaders
, base                                   # glibc-stub-base-<arch> (buildTree)
  # The cc that rebuilds the stubs - default bootstrap-gcc, the base's own
  # builder (matches the base's libc.so the stubs link against; no cross-gcc
  # dependency, so no cycle).
, buildCC ? (name: target: (mkCrossPkgs system target).buildPackages.gccWithoutTargetLibc)
  # emitIR: additionally emit the stub TUs as a single LLVM-IR text module
  # ($out/share/rpc-stub-ir/all.ll) for the rpc-wire-drift gate's wire-fact manifest.
  # Off by default (the harvest re-compiles every stub with clang, ~minutes) so
  # only the gate - which builds the `hurd-stubs-ir-<arch>` variant - pays it.
, emitIR ? false
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };
  buildFlags = import ./build-flags.nix { inherit lib; };
  toolchainPaths = import ./toolchain-paths.nix { inherit nixpkgs mkCrossPkgs; };

  hurdTargets = lib.filterAttrs (name: target: (target.platform or null) != "xen") targets;

  mkOne = name: target:
    let
      crossCC       = buildCC name target;
      tcPaths       = toolchainPaths system target;
      crossBinuRaw  = tcPaths.binutils;
      crossMig      = mig."mig-${name}";
      gnumach-hdrs  = gnumachHeaders."gnumach-headers-${name}";
      hurd-hdrs     = hurdHeaders."hurd-headers-${name}";
      stubBase      = base."glibc-hurd-${name}";
      tp            = target.crossTarget;
      salt          = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] tp;
    in
    pkgs.stdenv.mkDerivation ({
      pname   = "hurd-stubs${lib.optionalString emitIR "-ir"}-${tp}";
      version = "2.43";

      dontUnpack = true;
      # Same host tools glibc's build uses - notably perl, which the mig wrapper
      # script needs to locate migcom (File::Spec->abs2rel); without it the migcom
      # path collapses to bin//migcom and stub generation fails.
      nativeBuildInputs = (with pkgs; [ bison perl gawk python3 gnumake ]) ++ [ crossMig ];

      buildPhase = ''
        runHook preBuild
        host=${tp}

        # Copy the glibc build tree (src root with build/ inside) to a writable dir.
        cp -a ${stubBase}/tree ./g
        chmod -R u+w ./g
        srcdir=$PWD/g
        bdir=$srcdir/build

        # Rebuild the alias-headers sysroot the base configured against (the base's
        # original $TMPDIR/sysroot path is gone with its sandbox).  Recreate it from
        # THIS derivation's alias header inputs and repoint config.make at it; canon-
        # mapped below so the result is cross-host stable.
        sysroot=$PWD/sysroot
        mkdir -p $sysroot/include
        cp -rs ${gnumach-hdrs}/include/. $sysroot/include/ ; chmod -R u+w $sysroot/include
        cp -rs ${hurd-hdrs}/include/.    $sysroot/include/ ; chmod -R u+w $sysroot/include
        # The symlink farm above resolves to OLD store mtimes (make follows symlinks),
        # so the stubs read "up to date" and nothing rebuilds.  Overlay the RPC
        # interface .defs as REAL files with a fresh mtime: just those trigger the
        # stub regen (mig re-runs on the possibly-overridden alias surface) while every
        # OTHER header stays an old-mtime symlink, so nothing else recompiles.
        # mach/machine is a symlink to mach/<arch>; resolve real dirs and tolerate
        # any unwritable spot (the critical mach/*.defs + hurd/*.defs are plain dirs).
        for d in $sysroot/include/mach $sysroot/include/mach/i386 \
                 $sysroot/include/mach/x86_64 $sysroot/include/device \
                 $sysroot/include/hurd; do
          [ -d "$d" ] || continue
          for f in "$d"/*.defs; do
            [ -e "$f" ] || continue
            cp -L "$f" "$f.real" 2>/dev/null && mv -f "$f.real" "$f" 2>/dev/null || true
          done
        done
        # Swap the base's baked sysroot path -> ours throughout config.make.
        oldsys=$(sed -n 's/.*-isystem \([^ ]*\/sysroot\/include\).*/\1/p' $bdir/config.make | head -1)
        if [ -n "$oldsys" ]; then
          oldroot=''${oldsys%/include}
          grep -rl "$oldroot" $bdir/config.make $bdir/config.status 2>/dev/null \
            | xargs -r sed -i "s@$oldroot@$sysroot@g"
        fi

        cd $bdir

        export CC=${crossCC}/bin/${tp}-gcc
        export CXX=${crossCC}/bin/${tp}-g++
        export AR=${crossBinuRaw}/bin/${tp}-ar
        export AS=${crossBinuRaw}/bin/${tp}-as
        export LD=${crossBinuRaw}/bin/${tp}-ld
        export NM=${crossBinuRaw}/bin/${tp}-nm
        export OBJCOPY=${crossBinuRaw}/bin/${tp}-objcopy
        export RANLIB=${crossBinuRaw}/bin/${tp}-ranlib

        # Same determinism canon maps as glibc.nix, for THIS copy's paths, so the
        # rebuilt stubs are cross-host identical.  (The base's pre-built objects the
        # link reuses were already canon-mapped by glibc.nix to the SAME names.)
        export NIX_CFLAGS_COMPILE${salt}="${buildFlags.debugPrefixMapStr crossCC} -ffile-prefix-map=$bdir=${buildFlags.glibcCanonBuild} -ffile-prefix-map=$srcdir=${buildFlags.glibcCanonSrc} -ffile-prefix-map=$sysroot=${buildFlags.glibcCanonSysroot} -frandom-seed=${buildFlags.randomSeed} ''${NIX_CFLAGS_COMPILE${salt}:-} -ffile-prefix-map=$bdir/hurd/.=${buildFlags.glibcCanonBuild}/hurd"
        export NIX_DONT_SET_RPATH${salt}=1

        # Plain `make` (NOT rm + targeted - rm'ing the objects breaks glibc's rules):
        # the fresh .defs make only the mach/hurd stubs stale, so make rebuilds just
        # them (~the spike's 8 s) and leaves the rest of the base tree untouched.
        # With emitIR, CC is a transparent logging wrapper (execs the real gcc,
        # identical build) so the harvest below can replay glibc's EXACT per-TU
        # flags when re-emitting the stubs as LLVM IR.
        ${lib.optionalString emitIR ''
          printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" "$PWD" "$*" >> /tmp/cc.log\nexec %s "$@"\n' \
            "${crossCC}/bin/${tp}-gcc" > /tmp/cclog; chmod +x /tmp/cclog
          : > /tmp/cc.log
        ''}
        make -j"''${NIX_BUILD_CORES:-1}" ${lib.optionalString emitIR "CC=/tmp/cclog"}

        # Versioned install (glibc's install-time layout): the build emits an
        # unversioned mach/libmachuser.so carrying SONAME libmachuser.so.1 - ship it
        # AS the SONAME file, with the dev .so a symlink to it.
        mkdir -p $out/lib
        install -m555 mach/libmachuser.so  $out/lib/libmachuser.so.1
        install -m555 hurd/libhurduser.so  $out/lib/libhurduser.so.0.3
        install -m444 mach/libmachuser.a   $out/lib/libmachuser.a
        install -m444 hurd/libhurduser.a   $out/lib/libhurduser.a
        ln -s libmachuser.so.1   $out/lib/libmachuser.so
        ln -s libhurduser.so.0.3 $out/lib/libhurduser.so

        ${lib.optionalString emitIR ''
          # Re-emit each stub TU as LLVM IR for the rpc-wire-drift gate's wire-fact
          # manifest (flakes/tools/mig-wire-manifest.cpp).  glibc-native -O2 (glibc
          # #errors without __OPTIMIZE__) - the wire facts (msgh_id / struct field
          # offsets+values / msgt descriptors) are -O-invariant; -g dropped so
          # debug line numbers don't perturb them.  Replays glibc's captured per-TU
          # flags from the matching logged cwd, then llvm-links to ONE text module
          # (all.ll) for the gate's comparator.
          #
          # Scope - BOTH RPC_*.c (user stubs) AND *_server.c are harvested.  glibc
          # freezes server stubs only for the interfaces libc itself SERVES (exc,
          # msg, ...); those _S_*_server demuxers ARE frozen-in-libc, so they belong
          # in the gate (their reply-marshal stores + request-unmarshal icmp checks
          # are wire surface).  Translator-side servers (io/fs/...) are NOT frozen -
          # they rebuild with the kernel/translators under the in-tree mig - so the
          # frozen-vs-alias model doesn't apply; their wire compatibility with the
          # frozen libc client is the MIRROR of the user stub we already diff (same
          # mig emits both directions from one .defs), so the user-side facts cover
          # it.  Hence no separate translator-server harvest is needed.
          genir=$out/share/rpc-stub-ir; mkdir -p $genir
          clangbin=${pkgs.llvmPackages_19.clang-unwrapped}/bin/clang
          rep=$(grep -m1 -E 'RPC_[a-z].*\.c|_server\.c' /tmp/cc.log | cut -f2-)
          repflags=$(printf '%s' "$rep" | sed -E 's#[^ ]*RPC_[^ ]*\.c##g; s#[^ ]*[^ ]_server\.c##g; s/-Werror//g; s/ -g / /g; s#-o /[^ ]+##g; s/-MD//g; s/-MP//g; s#-MF [^ ]+##g; s#-MT [^ ]+##g')
          cd $bdir
          find $bdir \( -name 'RPC_*.c' -o -name '*_server.c' \) -type f | while read -r c; do
            nm=$(basename "$c" .c); sub=$(basename "$(dirname "$c")")
            $clangbin -target ${tp} -Wno-unknown-warning-option -Wno-error $repflags \
              -emit-llvm -c -o "$genir/$sub-$nm.bc" "$c" 2>>$genir/clang-errs.log \
              || echo "CLANG-FAIL $sub/$nm" >> $genir/clang-errs.log
          done
          n=$(find $genir -name '*.bc' | wc -l)
          [ "$n" -gt 0 ] || { echo "ERROR: no stub IR emitted"; head $genir/clang-errs.log; exit 1; }
          ${pkgs.llvmPackages_19.llvm}/bin/llvm-link $(find $genir -name '*.bc' | sort) -S -o $genir/all.ll
          rm -f $genir/*.bc $genir/clang-errs.log
          echo "emitted $n stub IR modules -> all.ll"
        ''}

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        # $out/lib populated in buildPhase (the build dir is gone by install).
        ls $out/lib/libmachuser.so.1  >/dev/null || { echo "ERROR: libmachuser.so.1 missing"; exit 1; }
        ls $out/lib/libhurduser.so.0.3 >/dev/null || { echo "ERROR: libhurduser.so.0.3 missing"; exit 1; }
        runHook postInstall
      '';

      dontPatchELF = true;
      passthru = { inherit target; };
      meta = with lib; {
        description = "Extracted Mach/Hurd RPC stub libs for ${tp}";
        platforms = platforms.all;
      };
    } // buildFlags.commonAttrs // helpers.mkCaAttrs true);
in
lib.mapAttrs' (name: target: lib.nameValuePair "hurd-stubs${lib.optionalString emitIR "-ir"}-${name}" (mkOne name target)) hurdTargets
