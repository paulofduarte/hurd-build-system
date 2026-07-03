# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# hurd-stubs - the extracted Mach/Hurd RPC stub libraries (libmachuser.so.1 +
# libhurduser.so.0.3), split OUT of glibc so an in-tree RPC change rebuilds just
# the stubs (~30 s) instead of the whole glibc (~100 s VM).
#
# Mechanism (the rt-base pattern applied to glibc): glibc's `buildtree` output ships
# the glibc OBJDIR (build/ only, source path canonicalised out); this derivation
# copies it alongside a fresh source checkout, points
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

{
  nixpkgs,
  system,
  targets,
  mig,
  gnumachHeaders,
  hurdHeaders,
  binutils, # cross-binutils-<name> attrset (absolute-path tools)
  base, # the glibc attrset; this reads its `buildtree` output (glibc.nix)
  # The glibc source (re-fetched from upstream).  The buildtree carries only the
  # OBJDIR with the source path canonicalised out (@GLIBC_SRCDIR@), so we supply a
  # fresh source checkout here and substitute it in - this is why the (large,
  # ftp-available) source is NOT in the buildtree's closure / the binary cache.
  srcInput,
  # The cc that rebuilds the stubs: the post-glibc cross-gcc (a name -> cc accessor).
  # NOT a bootstrap seed - those exist solely to build glibc, nothing downstream uses
  # them.  The stubs are glibc's own components, so its deployment compiler is the
  # right one: cross-gcc's --with-sysroot=glibc-hurd is the SAME glibc the buildtree
  # carries, and glibc builds -nostdinc (only the explicit, canonicalised includes are
  # searched), so the baked sysroot path never leaks.  Unwrapped (bakes
  # --with-as/--with-ld -> binutils), so determinism rides CPPFLAGS (config.make).
  buildCC,
  # emitIR: additionally emit the stub TUs as a single LLVM-IR text module
  # ($out/share/rpc-stub-ir/all.ll) for the rpc-wire-drift gate's wire-fact manifest.
  # Off by default (the harvest re-compiles every stub with clang, ~minutes) so
  # only the gate - which builds the `hurd-stubs-ir-<arch>` variant - pays it.
  emitIR ? false,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  buildFlags = import ./build-flags.nix { inherit lib; };

  hurdTargets = lib.filterAttrs (_name: target: (target.platform or null) != "xen") targets;

  mkOne =
    name: target:
    let
      crossCC = buildCC name target;
      crossBinu = binutils."cross-binutils-${name}";
      crossMig = mig."mig-${name}";
      gnumach-hdrs = gnumachHeaders."gnumach-headers-${name}";
      hurd-hdrs = hurdHeaders."hurd-headers-${name}";
      # The glibc `buildtree` output (the kept src+build/ tree) - see glibc.nix.
      stubBase = base."glibc-hurd-${name}".buildtree;
      tp = target.crossTarget;
    in
    pkgs.stdenv.mkDerivation (
      {
        pname = "hurd-stubs${lib.optionalString emitIR "-ir"}-${tp}";
        version = "2.43";

        dontUnpack = true;
        # Same host tools glibc's build uses - notably perl, which the mig wrapper
        # script needs to locate migcom (File::Spec->abs2rel); without it the migcom
        # path collapses to bin//migcom and stub generation fails.
        nativeBuildInputs =
          (with pkgs; [
            bison
            perl
            gawk
            python3
            gnumake
          ])
          ++ [ crossMig ];

        buildPhase = ''
          runHook preBuild
          host=${tp}

          # The buildtree ships the OBJDIR only (glibc.nix canonicalised the source
          # path out of it).  Reconstruct glibc's expected layout - a writable source
          # checkout with build/ NESTED inside it (objdir = $srcdir/build) - so glibc's
          # relative `-I../include` resolves to the source's include/ for BOTH the make
          # and the emitIR clang replay (which cd's to $bdir).  Writable: glibc's objdir
          # build writes into bdir, and the re-run mig stub generation needs a writable
          # srcdir.
          cp -a ${srcInput} ./g
          chmod -R u+w ./g
          cp -a ${stubBase}/build ./g/build
          chmod -R u+w ./g/build
          srcdir=$PWD/g
          bdir=$srcdir/build
          # glibc.nix renamed each per-subdir stamp.oS sentinel to stamp.oS.nixcase so
          # the cached buildtree carries NO case-colliding files (deterministic on a
          # case-sensitive store, restorable on a case-insensitive one).  Rename them
          # back so glibc's make finds the expected stamp.oS.  mv keeps the mtime (the
          # stamp stays "up to date", so only the overlaid stub .defs rebuild); on a
          # case-insensitive fs the target collapses onto stamp.os, which make tolerates
          # (the single file satisfies both the .os and .oS stamp targets).
          find $bdir -name 'stamp.oS.nixcase' -print | while IFS= read -r f; do
            mv -f "$f" "''${f%.nixcase}"
          done
          # Substitute the @GLIBC_SRCDIR@ sentinel with our checkout (mtime-preserving,
          # so only the stub .defs overlaid below go stale - everything else stays
          # "up to date" and is not recompiled).
          for f in $bdir/Makefile $bdir/config.make $bdir/config.status; do
            [ -f "$f" ] || continue
            sed "s|@GLIBC_SRCDIR@|$srcdir|g" "$f" > "$f.tmp$$" \
              && touch -r "$f" "$f.tmp$$" && mv -f "$f.tmp$$" "$f"
          done

          # Rebuild the alias-headers sysroot the base configured against (the base's
          # original $TMPDIR/sysroot path is gone with its sandbox).  Recreate it from
          # THIS derivation's alias header inputs and repoint config.make at it; canon-
          # mapped below so the result is cross-host stable.
          sysroot=$PWD/sysroot
          mkdir -p $sysroot/usr/include
          cp -rs ${gnumach-hdrs}/usr/include/. $sysroot/usr/include/ ; chmod -R u+w $sysroot/usr/include
          cp -rs ${hurd-hdrs}/usr/include/.    $sysroot/usr/include/ ; chmod -R u+w $sysroot/usr/include
          # The symlink farm above resolves to OLD store mtimes (make follows symlinks),
          # so the stubs read "up to date" and nothing rebuilds.  Overlay the RPC
          # interface .defs as REAL files with a fresh mtime: just those trigger the
          # stub regen (mig re-runs on the possibly-overridden alias surface) while every
          # OTHER header stays an old-mtime symlink, so nothing else recompiles.
          # mach/machine is a symlink to mach/<arch>; resolve real dirs and tolerate
          # any unwritable spot (the critical mach/*.defs + hurd/*.defs are plain dirs).
          for d in $sysroot/usr/include/mach $sysroot/usr/include/mach/i386 \
                   $sysroot/usr/include/mach/x86_64 $sysroot/usr/include/device \
                   $sysroot/usr/include/hurd; do
            [ -d "$d" ] || continue
            for f in "$d"/*.defs; do
              [ -e "$f" ] || continue
              cp -L "$f" "$f.real" 2>/dev/null && mv -f "$f.real" "$f" 2>/dev/null || true
            done
          done
          # Remap the base's dead sandbox sysroot path -> ours.  On linux nix's fixed
          # /build sandbox makes the base and this build share the path (oldroot ==
          # sysroot), so this is skipped; on darwin's per-build dirs it is needed.
          # The path is baked across config.make AND the generated dependency files
          # (*.udeps/*.o.d list <oldroot>/.../mach.defs as prereqs), so rewrite EVERY
          # text file that carries it (grep -rlI skips binaries -> no DWARF damage).
          # CRITICAL: do it MTIME-PRESERVING and non-in-place (sed to temp, touch -r,
          # mv) - `sed -i` is BSD-incompatible (darwin sandbox sed is Apple's) AND
          # bumps mtimes, which would make errno/config deps look fresh and trigger
          # spurious regens (errnos' `mkdir bits`, config.make-from-config.status)
          # that fail.  Preserving mtimes keeps the design's invariant: only the
          # overlaid stub .defs are fresh, so only the stubs rebuild.
          oldsys=$(sed -n 's/.*-isystem \([^ ]*\/sysroot\/usr\/include\).*/\1/p' $bdir/config.make | head -1)
          oldroot=''${oldsys%/usr/include}
          if [ -n "$oldsys" ] && [ "$oldroot" != "$sysroot" ]; then
            grep -rlI "$oldroot" $bdir 2>/dev/null | while IFS= read -r f; do
              sed "s@$oldroot@$sysroot@g" "$f" > "$f.tmp$$" \
                && touch -r "$f" "$f.tmp$$" && mv -f "$f.tmp$$" "$f" || rm -f "$f.tmp$$"
            done
          fi

          # glibc.nix canonicalised the bootstrap-gcc store path to the @GLIBC_CC@
          # sentinel so the cached buildtree doesn't drag the 168 MiB libc-free seed.
          # We relink with the post-glibc cross-gcc (crossCC), so substitute IT in
          # across every text file carrying the sentinel: config.make's sysincludes +
          # the CPPFLAGS-config gcc -fdebug-prefix-map, and the *.d/*.dt prereqs citing
          # the cc's internal headers.  The rewrite is uniform (one crossCC value
          # everywhere), so the -fdebug-prefix-map canonicalises cross-gcc's own path
          # too - cross-host determinism holds.  mtime-preserving / non-in-place, like
          # the sysroot remap above.
          grep -rlI '@GLIBC_CC@' $bdir 2>/dev/null | while IFS= read -r f; do
            sed "s|@GLIBC_CC@|${crossCC}|g" "$f" > "$f.tmp$$" \
              && touch -r "$f" "$f.tmp$$" && mv -f "$f.tmp$$" "$f" || rm -f "$f.tmp$$"
          done

          # Determinism: append THIS copy's canon maps to glibc's captured CPPFLAGS so
          # the rebuilt stubs are cross-host identical.  The unwrapped bootstrap-gcc has
          # no cc-wrapper NIX_CFLAGS_COMPILE channel; glibc bakes configure's CPPFLAGS
          # into config.make's CPPFLAGS-config, which Makeconfig applies to every .c/.os
          # compile (`CPPFLAGS = $(config-extra-cppflags) $(CPPFLAGS-config) ...`).  glibc
          # ALREADY baked the gcc + binutils -fdebug-prefix-maps (the base used the SAME
          # bootstrap-gcc + cross-binutils store paths) and the sysroot map was repointed
          # to $sysroot by the remap above - so only $bdir/$srcdir (this copy's build/src
          # dirs, disjoint from the base's dead sandbox paths, hence order-independent)
          # need adding.  hurd/. comes last so -ffile-prefix-map's last-match-wins
          # canonicalises the hurd subdir's `.` relative path after the broad $bdir map.
          # No -frandom-seed (the raw cc's default output-name seed is deterministic, as
          # in glibc.nix) and no NIX_DONT_SET_RPATH (the raw ld bakes no store rpath).
          echo "CPPFLAGS-config += -ffile-prefix-map=$bdir=${buildFlags.glibcCanonBuild} -ffile-prefix-map=$srcdir=${buildFlags.glibcCanonSrc} -ffile-prefix-map=$bdir/hurd/.=${buildFlags.glibcCanonBuild}/hurd" >> $bdir/config.make

          cd $bdir

          export CC=${crossCC}/bin/${tp}-gcc
          export CXX=${crossCC}/bin/${tp}-g++
          export AR=${crossBinu}/bin/${tp}-ar
          export AS=${crossBinu}/bin/${tp}-as
          export LD=${crossBinu}/bin/${tp}-ld
          export NM=${crossBinu}/bin/${tp}-nm
          export OBJCOPY=${crossBinu}/bin/${tp}-objcopy
          export RANLIB=${crossBinu}/bin/${tp}-ranlib

          # Plain `make` (NOT rm + targeted - rm'ing the objects breaks glibc's rules):
          # the fresh .defs make only the mach/hurd stubs stale, so make rebuilds just
          # them (~the spike's 8 s) and leaves the rest of the base tree untouched.
          # With emitIR, CC is a transparent logging wrapper (execs the real gcc,
          # identical build) so the harvest below can replay glibc's EXACT per-TU
          # flags when re-emitting the stubs as LLVM IR.
          ${lib.optionalString emitIR ''
            # Log each cc invocation's cwd+args so the IR harvest below can replay glibc's
            # exact per-TU flags.  Each invocation writes its OWN file under $TMPDIR/cc.d
            # (NOT a shared cc.log): under `make -j` hundreds of cc wrappers run at once,
            # and concurrent appends to one file SPLICE glibc's very long compile lines
            # into garbage (truncated -ffile-prefix-map, glued -M/path, stray source
            # fragments) - which then breaks the harvest's replayed clang flags.  One file
            # per shell PID ($$) has no write contention: concurrent cc wrappers are
            # distinct live processes (distinct PIDs -> distinct files), and a reused PID
            # only ever appends after the prior holder exited (never concurrent).  Uses
            # only the shell built-in $$ - NOT mktemp, which isn't on the cc wrapper's
            # PATH during glibc's build.  Write under $TMPDIR (the sandbox build temp),
            # NOT /tmp (the darwin nix sandbox forbids /tmp); $TMPDIR is expanded HERE so
            # the absolute path is baked into the wrapper.
            mkdir -p "$TMPDIR/cc.d"
            printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" "$PWD" "$*" >> "'"$TMPDIR"'/cc.d/$$"\nexec %s "$@"\n' \
              "${crossCC}/bin/${tp}-gcc" > "$TMPDIR/cclog"; chmod +x "$TMPDIR/cclog"
          ''}
          make -j"''${NIX_BUILD_CORES:-1}" ${lib.optionalString emitIR "CC=$TMPDIR/cclog"}

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
            clangbin=${pkgs.llvmPackages.clang-unwrapped}/bin/clang
            # `|| true`: grep exits 1 on no-match, which would abort under set -e/pipefail
            # before the clearer check below.
            rep=$(grep -rhE 'RPC_[a-z].*\.c|_server\.c' "$TMPDIR/cc.d" 2>/dev/null | head -1 | cut -f2- || true)
            [ -n "$rep" ] || { echo "ERROR: no RPC compile line captured (cc.d empty - cc wrapper logging broke)"; ls -la "$TMPDIR/cc.d" 2>/dev/null | head; exit 1; }
            repflags=$(printf '%s' "$rep" | sed -E 's#[^ ]*RPC_[^ ]*\.c##g; s#[^ ]*[^ ]_server\.c##g; s/-Werror//g; s/ -g / /g; s#-o /[^ ]+##g; s/-MD//g; s/-MP//g; s#-MF [^ ]+##g; s#-MT [^ ]+##g')
            cd $bdir
            # Per-TU progress so the harvest streams under `nix build -L` like the make
            # phase above (this loop is serial and the bulk of the -ir build; without it
            # the log goes dark after `make` until the summary).  Stdout only - clang's
            # own stderr stays captured to clang-errs.log for the failure check; the echo
            # never touches $out, so all.ll (and the derivation hash) is unaffected.
            echo "harvesting stub TUs as LLVM IR (per-TU clang replay):"
            find $bdir \( -name 'RPC_*.c' -o -name '*_server.c' \) -type f | while read -r c; do
              nm=$(basename "$c" .c); sub=$(basename "$(dirname "$c")")
              echo "  emit-ir $sub/$nm.c"
              $clangbin -target ${tp} -Wno-unknown-warning-option -Wno-error $repflags \
                -emit-llvm -c -o "$genir/$sub-$nm.bc" "$c" 2>>$genir/clang-errs.log \
                || echo "CLANG-FAIL $sub/$nm" >> $genir/clang-errs.log
            done
            n=$(find $genir -name '*.bc' | wc -l)
            [ "$n" -gt 0 ] || { echo "ERROR: no stub IR emitted"; head $genir/clang-errs.log; exit 1; }
            ${pkgs.llvmPackages.llvm}/bin/llvm-link $(find $genir -name '*.bc' | sort) -S -o $genir/all.ll
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

        # dontPatchELF rides commonAttrs.
        passthru = { inherit target; };
        meta = with lib; {
          description = "Extracted Mach/Hurd RPC stub libs for ${tp}";
          platforms = platforms.all;
        };
      }
      // buildFlags.commonAttrs
    );
in
lib.mapAttrs' (
  name: target:
  lib.nameValuePair "hurd-stubs${lib.optionalString emitIR "-ir"}-${name}" (mkOne name target)
) hurdTargets
