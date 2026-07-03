# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# NetBSD-as-rumpkernel for the Hurd - per-userland-target derivations
# (rump-stack step 4).  Provides the librump* set hurd's rumpdisk/rumpnet
# link: core (rump rumpuser rumpdev rumpdev_disk rumpdev_pci rumpvfs), the
# SATA/SCSI device libs, and the network set (rumpnet* + if_wm) - one NetBSD
# build produces them all.
#
# Source + recipe provenance (RUMP-STACK-FEASIBILITY round-2): rumpkernel has
# NO formal upstream; the Debian Hurd team's salsa package git is where
# development happens (`rumpkernel-dep-src`) - a vendored NetBSD-current src
# snapshot in buildrump.sh/ layout, the pci-userspace Mach glue, and a quilt
# series (Mach IRQ/VM patches + crossbuild TARGET_* support).  The build is a
# transliteration of debian/rules driven through NetBSD's build.sh, with the
# cross deltas Guix proved since 2023 (gnu/packages/hurd.scm, cross from
# x86_64-linux to i586/x86_64-pc-gnu):
#   - TARGET_CC/CXX/LD/AR/NM/MIG = our unwrapped cross tools (no multiarch
#     TARGET_LDADD - the cross-gcc's --with-sysroot resolves libc);
#   - MIG=<tp>-mig substituted into pci-userspace/src-gnu/Makefile.inc
#     (build.sh/nbmake does not export MIG there);
#   - PAWD=pwd, empty _GCC_CRT* env, HOST_CC = the native stdenv cc;
#   - configure runs INSIDE buildrump.sh/src/lib/librumpuser;
#   - install = manual harvest of rump/ headers + every librump*.{a,so*}.
#
# Three build entry points, in order: build.sh `tools` (host nbmake +
# wrappers) then `rump` (the components, cross); nbmake dependall in
# librumpuser (the POSIX hypercall layer); nbmake dependall in
# pci-userspace/src-gnu (Mach PCI glue - runs our mig over the sysroot's
# gnumach defs, compiles against libpciaccess + libirqhelp headers).
#
# Determinism: deliberately NOT canonicalised yet (repo policy: working
# first).  NetBSD's own rump version string is already reproducible
# (newvers.sh -R); the DWARF/objdir path maps are the deferred det pass.

{
  nixpkgs,
  system,
  targets,
  toolchainFor,
  mig,
  libpciaccess,
  libirqhelp,
  self,
  srcInput,
  forkUrl,
  buildRevToken ? null,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  helpers = import ../lib { inherit lib; };

  # WORK-pin version composition (like flakes/hurd), seeded from the Debian
  # changelog head (`rumpkernel (0~20250111-8) ...`); `~` is not a valid nix
  # store-name char -> `-` (same as Guix).  Bounded substring:
  # builtins.match is a recursive std::regex (see flakes/libacpica).
  upstreamVersion =
    let
      match = builtins.match "rumpkernel [(]([^)]+)[)].*" (
        builtins.substring 0 200 (builtins.readFile (srcInput + "/debian/changelog"))
      );
    in
    if match == null then "unknown" else lib.replaceStrings [ "~" ] [ "-" ] (builtins.head match);
  version = helpers.composeVersion {
    inherit
      upstreamVersion
      srcInput
      self
      forkUrl
      buildRevToken
      ;
  };

  # target name -> NetBSD machine arg.
  nbCpu = {
    i686 = "i386";
    x86_64 = "amd64";
  };

  userlandTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;

  mkOne =
    name: target:
    let
      tp = target.crossTarget; # e.g. i686-gnu
      cpu = nbCpu.${name};
      tc = toolchainFor target;
      inherit (tc) cc;
      binu = tc.binutils;
      crossMig = mig."mig-${name}";
      pciPkg = libpciaccess."libpciaccess-${name}";
      irqPkg = libirqhelp."libirqhelp-${name}";
    in
    pkgs.stdenv.mkDerivation {
      pname = "rumpkernel-${tp}";
      inherit version;
      src = srcInput;

      # Host side: the stdenv cc builds the NetBSD tools (nbmake + wrappers);
      # zlib for the host tools (Guix parity); autoconf/automake for
      # librumpuser's configure; patchelf for darwin's audit-tmpdir fixup.
      # Target side: the cross toolchain + our mig.
      nativeBuildInputs =
        (with pkgs; [
          autoconf
          automake
          zlib
          patchelf
          perl # the <tp>-mig driver script shells perl (cpp flag plumbing)
        ])
        ++ [
          # etc/Makefile's distrib-dirs (the step that CREATES the destdir
          # METALOG) shells `hostname`, absent in the sandbox - and a real one
          # would leak the build host's name.  Fixed shim: deterministic + the
          # value is inert (only decorates distrib-dirs output).
          (pkgs.writeShellScriptBin "hostname" "echo rumpbuild")
          cc
          binu
          crossMig
        ];

      # 1. the Debian quilt series (Mach glue + crossbuild TARGET_* support);
      # 2. Guix's MIG fix: build.sh/nbmake does not export MIG into
      #    pci-userspace, so pin the cross one in its Makefile.inc.
      patchPhase = ''
        runHook prePatch
        while IFS= read -r p; do
          case "$p" in ""|\#*) continue ;; esac
          echo "applying debian/patches/$p"
          patch --force -p1 < "debian/patches/$p"
        done < debian/patches/series
        runHook postPatch
      '';
      postPatch = ''
        sed -i.bak 's|MIG=mig|MIG=${tp}-mig|' pci-userspace/src-gnu/Makefile.inc
        rm pci-userspace/src-gnu/Makefile.inc.bak
        grep -n 'MIG=' pci-userspace/src-gnu/Makefile.inc
        # bsd.kinc.mk's include-dir recipe shells a HARDCODED /bin/rm - absent
        # in the nix sandbox, and its failure leaves the destdir/METALOG
        # uncreated (the whole includes pass then cascades).  PATH rm is fine.
        # (bsd.obj.mk's /bin/pwd twin is already neutralised by PAWD=pwd.)
        sed -i.bak 's|/bin/rm |rm |' buildrump.sh/src/share/mk/bsd.kinc.mk
        rm buildrump.sh/src/share/mk/bsd.kinc.mk.bak
      '';

      # librumpuser (the POSIX hypercall layer) is the only autoconf piece;
      # configure it in place with the cross cc (dh_auto_configure -D parity).
      configurePhase = ''
        runHook preConfigure
        (
          cd buildrump.sh/src/lib/librumpuser
          CC=${tp}-gcc ./configure --host=${tp} --prefix=/usr
        )
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        # Env contract of build.sh + the crossbuild patch (Debian rules +
        # Guix setenv phase): host cc for the tools, TARGET_* cross tools for
        # the components, PAWD for the pwd -P calls, empty _GCC_CRT* so the
        # NetBSD makefiles don't inject their own crt objects.
        export HOST_CC=cc
        export HOST_CPPFLAGS=-D_GNU_SOURCE
        export HOST_SH="$(command -v sh)"
        export TARGET_AR=${tp}-ar
        export TARGET_CC=${tp}-gcc
        export TARGET_CXX=${tp}-g++
        export TARGET_LD=${tp}-ld
        export TARGET_NM=${tp}-nm
        export TARGET_MIG=${tp}-mig
        # The crossbuild patch's toolwrappers also honour these three; their
        # PATH fallbacks are the HOST tools, which breaks on a host whose
        # binutils lack the target bfd (aarch64 objcopy vs x86_64-gnu .pico:
        # "Unable to recognise the architecture").  Guix never hit it - their
        # build host is x86_64-linux, same CPU as the target.
        export TARGET_OBJCOPY=${tp}-objcopy
        export TARGET_RANLIB=${tp}-ranlib
        export TARGET_STRIP=${tp}-strip
        # NO Debian-style TARGET_LDADD: pointing -B/-L at the real glibc makes
        # ld find libc.so (a GROUP script with ABSOLUTE /usr/lib members)
        # OUTSIDE the link's --sysroot=<destdir>, and GNU ld resolves a
        # script's absolute members sysroot-relative ONLY when the script
        # itself sits inside the sysroot - so the members "cannot find".
        # Instead the destdir sysroot is SEEDED with the glibc libs (below):
        # gcc's --sysroot retarget then finds crti.o/libc.so/-lpthread inside
        # it and the GROUP resolves sysroot-relative, exactly as on a real
        # system root.
        export MIG=${tp}-mig
        export PAWD=pwd
        export _GCC_CRTENDS= _GCC_CRTEND= _GCC_CRTBEGINS= _GCC_CRTBEGIN= _GCC_CRTI= _GCC_CRTN=

        mkdir -p obj
        top=$PWD
        # Pre-create the destdir METALOG: every consumer APPENDS (nbinstall -M,
        # distrib-dirs' mtree >>), but under -j the includes pass races ahead
        # of do-distrib-dirs (the nominal creator; Debian hides this with its
        # -j1 default) and nbinstall's open() has no O_CREAT.  An empty seed
        # file is sound - we harvest the libs manually and never read METALOG.
        mkdir -p "$top/buildrump.sh/src/obj/destdir.${cpu}"
        : > "$top/buildrump.sh/src/obj/destdir.${cpu}/METALOG"
        # Seed the destdir sysroot with the glibc libs (symlink farm): the
        # rump .so links run ld with --sysroot=<destdir>, which REPLACES the
        # cross-gcc's baked glibc sysroot - crt objects, -lpthread and libc
        # itself must exist inside it.  -n keeps NetBSD's own later installs
        # from being clobbered.
        dst="$top/buildrump.sh/src/obj/destdir.${cpu}"
        mkdir -p "$dst/usr"
        cp -Rsn ${tc.sysroot}/usr/lib "$dst/usr/"
        chmod -R u+w "$dst/usr/lib" # cp -R keeps the store's 0555 dir modes
        # usr-merge view for the link lines' sysroot-relative -L=/lib.
        ln -sn usr/lib "$dst/lib"
        test -e "$dst/usr/lib/libc.so" || { echo "sysroot seed failed" >&2; exit 1; }
        # pci-userspace compiles against <pciaccess.h>/irqhelp.h and links
        # -lpciaccess: its compiles get -I<destdir>/usr/include (NOT our store
        # -I set - its Makefile bypasses the wrapper-baked CPPFLAGS), so seed
        # headers AND libs next to the glibc ones (real ELFs, symlinks fine).
        mkdir -p "$dst/usr/include"
        cp -Rsn ${pciPkg}/usr/lib "$dst/usr/"
        cp -Rsn ${pciPkg}/usr/include "$dst/usr/"
        cp -Rsn ${irqPkg}/usr/lib "$dst/usr/"
        cp -Rsn ${irqPkg}/usr/include "$dst/usr/"
        chmod -R u+w "$dst/usr/lib" "$dst/usr/include"
        # glibc's script libs (libc.so is a GROUP with ABSOLUTE /usr/lib
        # members): GNU ld sysroot-prefixes a script's absolute members IFF
        # the script is a real file INSIDE the sysroot - a store symlink makes
        # ld treat it as outside (members resolve on the host root: "cannot
        # find /usr/lib/libc.so.0.3"), while rewriting members to store paths
        # gets them force-prefixed instead ("cannot find <store> inside
        # <destdir>").  So: materialise each seeded SCRIPT as a real file,
        # VERBATIM - its /usr/lib members then prefix to this destdir and
        # resolve via the seeded symlinks.  (Same root cause the darwin spike
        # fixed with a full cp -RL; this is the minimal version.)
        for f in "$dst"/usr/lib/lib*.so*; do
          [ -L "$f" ] || continue
          tgt=$(readlink "$f")
          if grep -aqE "GROUP|INPUT" "$tgt" 2>/dev/null && ! grep -aq $'\x7fELF' "$tgt" 2>/dev/null; then
            rm "$f"
            cat "$tgt" > "$f"
            echo "materialised linker script: $(basename "$f")"
          fi
        done
        (
          cd buildrump.sh/src
          # -V vars are baked into the generated nbmake-${cpu} wrapper, so the
          # CPPFLAGS here (incl. our libpciaccess/libirqhelp includes for
          # pci-userspace) reach the dependall passes below too.  Flag set
          # verbatim from debian/rules override_dh_auto_build-arch, minus the
          # multiarch TARGET_LDADD (see the sysroot seed above), plus Guix's
          # -Wno-error=sign-compare.  MKPROFILE=no is ours: gcc 16 makes
          # "-pg without -mfentry" a hard -Werror on i386 (.po objects), and
          # nothing in the rumpdisk/rumpnet chain links profile archives.
          BSDOBJDIR="$top/obj" sh ./build.sh \
            -V TOOLS_BUILDRUMP=yes \
            -V MKPROFILE=no \
            -V MKBINUTILS=no -V MKGDB=no -V MKGROFF=no -V MKDTRACE=no -V MKZFS=no \
            -V TOPRUMP="$top/buildrump.sh/src/sys/rump" \
            -V BUILDRUMP_CPPFLAGS="-Wno-error=stringop-overread -Wno-error=sign-compare" \
            -V RUMPUSER_EXTERNAL_DPLIBS=pthread \
            -V CPPFLAGS="-Wno-error=unused-but-set-variable -I../../obj/destdir.${cpu}/usr/include -I${pciPkg}/usr/include -I${irqPkg}/usr/include -D_FILE_OFFSET_BITS=64 -DRUMP_REGISTER_T=int -DRUMPUSER_CONFIG=yes -DNO_PCI_MSI_MSIX=yes -DNUSB_DMA=1 -DPAE -DBUFPAGES=16" \
            -V CWARNFLAGS="-Wno-error=maybe-uninitialized -Wno-error=address-of-packed-member -Wno-error=unused-variable -Wno-error=stack-protector -Wno-error=array-parameter -Wno-error=array-bounds -Wno-error=stringop-overflow" \
            -V LIBCRTBEGIN=" " -V LIBCRTEND=" " -V LIBCRT0=" " -V LIBCRTI=" " \
            -V MIG=mig \
            -V _GCC_CRTENDS=" " -V _GCC_CRTEND=" " \
            -V _GCC_CRTBEGINS=" " -V _GCC_CRTBEGIN=" " \
            -V _GCC_CRTI=" " -V _GCC_CRTN=" " \
            -U -u -T ./obj/tooldir -m ${cpu} -j ''${NIX_BUILD_CORES:-1} \
            tools rump
        )
        RUMPMAKE=$top/buildrump.sh/src/obj/tooldir/bin/nbmake-${cpu}
        ( cd buildrump.sh/src/lib/librumpuser && RUMPRUN=true "$RUMPMAKE" -j ''${NIX_BUILD_CORES:-1} dependall )
        ( cd pci-userspace/src-gnu && "$RUMPMAKE" -j ''${NIX_BUILD_CORES:-1} dependall )
        runHook postBuild
      '';

      # Manual harvest (debian/rules override_dh_auto_install): the rump/
      # header tree + every librump* archive/solib the build scattered across
      # the src and obj trees.  cp -an skips the duplicated copies (Guix
      # skips-if-exists for the same reason); *.map dropped like Debian.
      installPhase = ''
        runHook preInstall
        mkdir -p $out/usr/include $out/usr/lib
        cp -a buildrump.sh/src/sys/rump/include/rump $out/usr/include/
        find buildrump.sh/src obj \( -type f -o -type l \) -name "librump*.so*" \
          -exec cp -an {} $out/usr/lib/ \;
        find buildrump.sh/src obj -type f -name "librump*.a" \
          -exec cp -an {} $out/usr/lib/ \;
        rm -f $out/usr/lib/*.map
        runHook postInstall
      '';

      # Same output-hygiene set as the other rump-stack libs.
      dontPatchELF = true;
      dontStrip = true;
      dontPatchShebangs = true;

      passthru = { inherit target; };
      meta = with lib; {
        description = "NetBSD rumpkernel for ${tp} (hurd rumpdisk/rumpnet dep)";
        platforms = platforms.all;
        # A hodgepodge - see debian/copyright in the source; the rump glue is
        # BSD-2/BSD-3, drivers carry their NetBSD licences.
        license = with licenses; [
          bsd2
          bsd3
        ];
      };
    };
in
lib.mapAttrs' (
  name: target: lib.nameValuePair "rumpkernel-${name}" (mkOne name target)
) userlandTargets
