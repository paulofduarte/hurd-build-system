# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-toolchain components - per-target derivations, built against the
# patched `<cpu>-gnu` nixpkgs from pkgs.nix.
#
# Outputs (per non-xen userland target):
#   cross-binutils-<arch>     cross-binutils, target-prefixed (`i686-gnu-as`, ...).
#                             No libc dep; safe to build first.
#   cross-gcc-stage1-<arch>   gccWithoutTargetLibc - bare driver + cc1 + libgcc.a
#                             (no libgcc_s/libstdc++/libc).  The libc-free cc that
#                             compiles gnumach-headers, mig, and glibc-hurd
#                             (gnumach's configure forces -ffreestanding -nostdlib,
#                             so the link test needs no libc).
#   cross-gcc-<arch>          final cross-gcc: C + C++, libgcc_s/libstdc++ linked
#                             against the REFERENCE glibc-hurd.  Same nixpkgs gcc
#                             builder as stage-1, withoutTargetLibc=false + libcCross.
#   toolchain-<arch>          THE toolchain: the wrapped cross-cc (final gcc + the
#                             WORKING glibc-hurd + a glibc-hurd-wrapped binutils).
#                             What the dev shell, gnumach, and the Hurd userland
#                             build with, and what the cache workflow builds.
#
# `mkAll` emits the pre-libc components (binutils + stage-1).  The final
# gcc + wrapped toolchain need glibc-hurd, so `mkFinal` takes the
# reference/working glibc-hurd attrsets and is invoked from packages.nix
# after both glibcs are built.
#
# `hurdTargets` filters target-archs.nix to the non-xen userland targets
# (i686, x86_64).  The xen variants share their CPU sibling's toolchain (same
# `<cpu>-gnu` ABI; the kernel links -nostdlib so the working glibc-hurd sysroot
# is irrelevant), so packages.nix maps them onto the sibling toolchain.

{ nixpkgs, mkCrossPkgs }:

let
  lib = nixpkgs.lib;
  buildFlags = import ./build-flags.nix { inherit lib; };

  hurdTargets = targets:
    lib.filterAttrs (name: target: (target.platform or null) != "xen") targets;

  # A complete cross-gcc: nixpkgs' own gcc builder with the target libc present
  # (withoutTargetLibc=false) so it builds libgcc_s + libstdc++, C++ enabled,
  # shared libs on.  Reusing the stage-1 cc's `.override` keeps every nixpkgs
  # gcc patch/phase; only the libc-facing knobs flip.
  #
  # `targetLibc` is the glibc libgcc_s / libstdc++ link against = the REFERENCE
  # glibc; the resulting userland cc's libgcc_s/libstdc++ are the ABI-stable
  # runtime (valid against the working glibc).  Rebuilds only on a ref bump,
  # never on a working-glibc hack.
  mkGcc = system: target: targetLibc:
    let
      bp  = (mkCrossPkgs system target).buildPackages;
      gcc = bp.gccWithoutTargetLibc.cc.override {
        withoutTargetLibc = false;
        langCC            = true;
        libcCross         = targetLibc;
        enableShared      = true;
      };
      # The per-target salt the cross bintools-wrapper suffixes its env vars with
      # (e.g. NIX_LDFLAGS_BEFORE_x86_64_gnu).  Derived from the target config:
      # `bp.stdenv`'s salt is the native build platform (`_arm64_apple_darwin`),
      # NOT the cross ld the libgcc link runs through, so it would be wrong.
      salt = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] target.crossTarget;
    in
    # --disable-libgomp: the Hurd userland links only libgcc(_s) + libstdc++; the
    # OpenMP runtime is unused, and gcc 15's libgomp fails to build against the
    # Hurd glibc headers (affinity-fmt.c trips -Werror=discarded-qualifiers).
    # nixpkgs only passes the flag on the withoutTargetLibc (stage-1) path; the
    # with-target-libc final gcc re-enables it, so append it back here.
    #
    # mechanism #2: gcc builds libgcc_s/libstdc++ by linking `-lc` against the
    # --prefix=/ reference glibc, whose libc.so is a GNU ld GROUP script with
    # absolute /lib members.  ld resolves those only with `--sysroot=${ref}`, but
    # the nix ld-wrapper strips a command-line `--sysroot` under sandbox purity -
    # so gcc's own --with-sysroot/SYSROOT_SPEC never reaches the raw ld.  Same
    # wall the userland link hits; same fix - feed the wrapper `--sysroot=${ref}`
    # via NIX_LDFLAGS_BEFORE_<salt>, which add-flags.sh keeps and applies to the
    # raw ld AFTER the strip.  (The wrapper gcc links through is the cross-stdenv's,
    # not one we can wrap; the env var is the channel that reaches it.)
    #
    # patchelf: building libgcc_s/libstdc++ runs `patchelf --clear-execstack` on
    # each installed .so (same glibc Makerules path); without patchelf on PATH the
    # build logs "patchelf: command not found" per library.  Adding it also
    # registers patchelf's `--shrink-rpath` setup-hook (don't want it mutating the
    # cross libs' RPATHs), so dontPatchELF turns ONLY that hook off, leaving the
    # clear-execstack call intact.  (Same pairing as glibc.nix.)
    #
    # --with-ld: cross-host determinism for libstdc++.so.  libtool's C++ tag only
    # enables `--whole-archive` for convenience libs when `$CC -print-prog-name=ld
    # --help` advertises `no-whole-archive`.  gcc records no absolute ld, returns
    # the bare name `ld`, and libtool runs the BUILD host's native ld: GNU on Linux
    # (-> --whole-archive, archive order) vs macOS cctools on darwin (-> libtool
    # EXTRACTS each archive and lists objects via `find ... | sort`, ALPHABETICAL).
    # The two orders give different .text/.cold layouts -> non-reproducible
    # libstdc++.so.  Pinning gcc's ld to the GNU cross ld makes the probe succeed
    # everywhere -> --whole-archive -> byte-identical.  Points at the WRAPPED bintools
    # ld (the one the build already links through), so mechanism #2's --sysroot is
    # preserved.
    gcc.overrideAttrs (old: {
      configureFlags    = (old.configureFlags or []) ++ [
        "--disable-libgomp"
        "--with-ld=${bp.gccWithoutTargetLibc.bintools}/bin/${target.crossTarget}-ld"
      ];
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ bp.patchelf ];
      dontPatchELF      = true;
      # Drop nixpkgs' `enableLibGccOutput`: it splits libgcc_s.so into a separate
      # `libgcc` output and runs `patchelf --set-rpath ""` on it.  It's gated
      # `&& !hostPlatform.isDarwin`, so a Linux-built gcc WIPES libgcc_s's RUNPATH
      # while a darwin-built one keeps mechanism #2's `/lib` - cross-host divergence
      # in the shipped libgcc_s.so.1.  The patchelf wipe also reshuffles sections,
      # so no post-hoc `--set-rpath /lib` reconstructs the pristine layout; fix at
      # the source.  Filtering the output + phase off makes EVERY host emit the
      # pristine `/lib` libgcc_s.  Safe: our standalone glibc-hurd never consumes
      # gcc's `libgcc` output / `passthru.libgcc`.  No-op on darwin.  (Names are
      # nixpkgs-internal - gcc/common/libgcc.nix.)
      outputs        = lib.filter (o: o != "libgcc") (old.outputs or [ "out" ]);
      preFixupPhases = lib.filter (p: p != "preFixupLibGccPhase") (old.preFixupPhases or []);
      env               = old.env // {
        # mechanism #2: `--sysroot` so the --prefix=/ targetLibc's /lib GROUP
        # resolves at the libgcc_s/libstdc++ link.  Rides NIX_LDFLAGS_BEFORE so it
        # survives the ld-wrapper's purity strip.  No `-rpath`: the shipped
        # libgcc_s/libstdc++ carry NO DT_RUNPATH, matching Debian GNU/Hurd and the
        # rest of our dist - they resolve libc from /lib via the loader's default
        # search path (glibc's default-rpath=/lib + /etc/ld.so.cache).
        "NIX_LDFLAGS_BEFORE${salt}" =
          (old.env."NIX_LDFLAGS_BEFORE${salt}" or "") + " --sysroot=${targetLibc}";
        # Stop the wrapper auto-deriving -rpath from the -L dirs, and drop
        # nixpkgs' explicit store -rpath (keep -L + -rpath-link for build-time
        # resolution) - else `${targetLibc}/lib` would be baked.
        "NIX_DONT_SET_RPATH${salt}" = "1";
        EXTRA_LDFLAGS_FOR_TARGET = lib.replaceStrings
          [ " -Wl,-rpath,${targetLibc}/lib" ] [ "" ]
          (old.env.EXTRA_LDFLAGS_FOR_TARGET or "");
        # The TARGET runtime libs (libgcc_s, libstdc++ - what dist-libgcc ships)
        # get the shared baseCflags (build-flags.nix), the same -g -O2 as the rest
        # of the dist, defined in ONE place.  CFLAGS_FOR_TARGET only - the gcc
        # compiler proper keeps its own build flags.
        CFLAGS_FOR_TARGET   = buildFlags.baseCflags;
        CXXFLAGS_FOR_TARGET = buildFlags.baseCflags;
      };
      # libstdc++'s gdb pretty-printer hook (libstdc++.so.*-gdb.py) records absolute
      # pythondir/libdir and derives a RELATIVE offset from them at load time to stay
      # relocatable.  nixpkgs bakes the build-host store prefix into them -> host-
      # varying.  Rewrite them to the paths our --prefix=/ dist deploys to - /lib and
      # /share/gcc-<ver>/python - so the hook is host-independent AND correct on the
      # target (matching glibc's deployPrefix layout).  `$d` is the .py's own dir (the
      # store libdir), so this is target-triple-agnostic.  No `sed -i` (portable sed).
      postFixup = (old.postFixup or "") + ''
        for f in "$lib"/*/lib/*-gdb.py "$lib"/lib/*-gdb.py; do
          [ -e "$f" ] || continue
          d=$(dirname "$f")
          sed -e "s|$d|/lib|g" -e "s|$lib/share|/share|g" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
        done
      '';
    });

  # The wrapped cross-cc.  `cc` is the reference-built gcc; the cc-wrapper and
  # bintools-wrapper point at the WORKING glibc (headers / crt / ld.so / augmented
  # libc.so GROUP).  Re-pointing `working` is a wrapper rebuild (seconds) -
  # wrapCCWith never recompiles `cc`, so hacking the working glibc doesn't rebuild
  # gcc.  We wrap binutils-unwrapped rather than the default cross binutils wrapper
  # to avoid dragging in nixpkgs' own glibc, whose meta.platforms gate refuses the
  # Hurd target at eval time.
  wrappedToolchain = system: target: { cc, working }:
    let
      bp   = (mkCrossPkgs system target).buildPackages;
      salt = "_" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] target.crossTarget;
    in
    bp.wrapCCWith {
      inherit cc;
      libc     = working;
      bintools = bp.wrapBintoolsWith {
        bintools = bp.binutils-unwrapped;
        libc     = working;
        # No --sysroot.  How the deployable glibc's libc.so GROUP ld-script resolves
        # at link depends on which `working` we wrap:
        #  - The gated re-export farm (abi-check.nix mkAbiChecked) the userland
        #    toolchain links against rewrites the GROUP to BARE NAMES (libc.so.0.3,
        #    libmachuser.so, ...).  ld resolves them via the -L"${working}/lib" the
        #    wrapper already adds - no --sysroot, never doubled, host-uniform.
        #  - A RAW deployable glibc used as a glibc buildCC's prior libc keeps its
        #    /lib GROUP, but the nix ld-wrapper strips a CLI --sysroot under purity
        #    (so it never reached ld in a Linux sandbox anyway), and the glibc build's
        #    configure link tests don't bind the prior libc's full GROUP, so they pass
        #    without it.  On darwin --sysroot WAS honoured and doubled an already-
        #    absolute GROUP member ("cannot find ... inside ...").  So bare names need no
        #    sysroot at all.
        #
        # NIX_DONT_SET_RPATH: stop the ld-wrapper auto-baking a /nix/store rpath to
        # working/lib on anything linked through this wrapper; glibc's slibdir=/lib +
        # SONAME NEEDED resolve via the target /lib.  (DRY: in the wrapper, not a
        # per-build export in glibc.nix.)
        extraBuildCommands = ''
          echo "export NIX_DONT_SET_RPATH${salt}=1" >> $out/nix-support/add-local-ldflags-before.sh
        '';
      };
    };
in

{
  inherit mkGcc wrappedToolchain hurdTargets;

  # Pre-libc components merged into packages.<system>: two outputs per hurd
  # target (binutils + gcc-stage1).  The 2-pass gcc/glibc chain (stage-1 nolibc
  # gcc -> ref glibc -> final gcc -> work glibc -> wrapped toolchain) is
  # orchestrated in packages.nix, since it interleaves glibc.nix calls (which
  # thread mig/headers) with `mkGcc`.
  mkAll = system: targets:
    let
      hts = hurdTargets targets;
      pairs = lib.concatLists (lib.mapAttrsToList (name: target: [
        { name = "cross-binutils-${name}";   value = (mkCrossPkgs system target).buildPackages.binutils-unwrapped; }
        { name = "cross-gcc-stage1-${name}"; value = (mkCrossPkgs system target).buildPackages.gccWithoutTargetLibc; }
      ]) hts);
    in
    lib.listToAttrs pairs;
}
