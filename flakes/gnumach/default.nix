# GNU Mach kernel — per-target derivations.
#
# One nix derivation per target (autoreconf + configure + make +
# make install) producing the bootable kernel image + install tree.
#
# Output layout:
#   $out/boot/gnumach              bootable kernel — raw binary
#                                  (objcopy -O binary) on aarch64 so
#                                  qemu's -kernel accepts it, ELF
#                                  with debug info on i386/x86_64
#                                  (qemu's -kernel handles ELF there).
#   $out/boot/gnumach.elf          unstripped ELF with DWARF — only on
#                                  aarch64, copied from the build dir
#                                  in postInstall.  Pair to the raw
#                                  binary above for gdb / addr2line.
#                                  No need on i386/x86_64 since
#                                  boot/gnumach is already the ELF.
#   $out/include/mach/...          public headers (same as the headers
#                                  sub-flake produces).
#   $out/share/...                 .defs + .msgids.
#
# Returned shape — one attribute per entry in `targets`, named
# `gnumach-<name>`.  The root flake merges what comes back into
# `packages.<system>`.
#
# Per-target attrset fields (see target-archs.nix + flake.nix):
#   crossTarget : nixpkgs cross-system config (`<cpu>-gnu`) — drives the
#                 wrapped cross toolchain, the output pname, and the
#                 matching cross-MIG sibling lookup.
#   platform    : "at" / "xen" — fed to gnumach's --enable-platform= flag.
#
# Source comes from the pinned `gnumach-src` flake input (a github fork rev
# locked in flake.lock; see flake.nix + flakes/sources), NOT the local
# src/gnumach working clone — that is a dev convenience populated by `make
# srcs`.
#
# `mig` is the attrset returned by flakes/mig (the sibling sub-flake).
# We look up "mig-<name>" for the matching target and add its derivation
# to nativeBuildInputs; nixpkgs' cross-stdenv puts the wrapper's bin/
# on PATH automatically.  gnumach's configure runs `AC_CHECK_TOOL([MIG],
# [mig])` and `AC_CHECK_PROG([USER_MIG], [<crossTarget>-mig])` — the mig
# sub-flake ships both the primary `<crossTarget>-mig` binary AND a
# `<crossPrefix>mig` symlink alias, so both checks self-discover via
# PATH with no `MIG=` override needed here.
#
# Tests are intentionally disabled (doCheck = false) until the kernel
# test-suite is wired up to run inside the nix sandbox — the existing
# `make check-mach` harness assumes the in-repo work/ tree and a host
# qemu, neither of which the sandbox provides.  Until then, kernel
# tests stay under the parent Makefile's `check-mach` target.

{ nixpkgs, system, targets, mig, toolchainFor, self, srcInput, forkUrl }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  # Upstream version parsed from version.m4 (AC_PACKAGE_VERSION).  If
  # upstream bumps the m4 file, the parser picks it up automatically.
  upstreamVersion = helpers.parseM4Version (srcInput + "/version.m4");

  # PACKAGE_VERSION composed at eval time — fully pure.
  # See flakes/lib/default.nix (composeVersion) for the format.
  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self forkUrl;
  };

  mkOne = name: target:
    let
      crossMig  = mig."mig-${name}";
      tp        = target.crossTarget;                 # e.g. i686-gnu
      # The wrapped cross-cc — the SAME `toolchain-<arch>` the userland +
      # dev shell use (the xen variants get their CPU sibling's).  The
      # kernel builds freestanding (configure.ac forces -ffreestanding
      # -nostdlib), so glibc-hurd is never linked — but using the wrapped
      # cc keeps the kernel on the one toolchain.  Built with the native
      # stdenv (like the Hurd userland): the `<cpu>-gnu` cross stdenv would
      # pull nixpkgs' meta-gated glibc; cross tools come in by name below.
      toolchain = toolchainFor target;
      pname     = "gnumach-${tp}";
    in
    pkgs.stdenv.mkDerivation ({
      inherit pname;

      # Drives both the store path suffix and (via the sed below) the
      # binary's PACKAGE_VERSION — same string, traceable on both sides.
      version = fullVersion;

      # The pinned `gnumach-src` input (a github fork rev locked in
      # flake.lock).  nix builds exactly that — never the local src/gnumach
      # working clone — so the built bytes always match the version string's
      # `srcInput.shortRev`.
      src = srcInput;

      # autoreconfHook supplies autoconf/automake/libtool/m4 + runs autoreconf.
      # texinfo: the kernel build runs makeinfo (mach.info).  perl: the MIG
      # wrapper shells out to perl when generating stubs.  awk comes from
      # stdenv.  The wrapped cross cc (provides ${tp}-gcc + the cross
      # binutils) + cross mig (provides ${tp}-mig) are found by configure's
      # host-prefixed tool search; CC is pinned in preConfigure below.
      # patchelf: the stdenv audit-tmpdir fixup runs `patchelf --print-rpath`
      # on each output ELF to verify no $TMPDIR build-dir path leaked into the
      # kernel's RPATH.  Observed on this host (aarch64-darwin) the default
      # stdenv ships no patchelf, so the audit can't run — it logged "patchelf:
      # command not found".  Add it so the audit works.  (For the freestanding
      # kernel this finds no .dynamic section / no RPATH, so it's effectively
      # a no-op, but it runs honestly rather than silently skipping.)
      # dontPatchELF below disables patchelf's OTHER hook (--shrink-rpath),
      # which its setup-hook would otherwise register here.
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ texinfo perl patchelf ])
        ++ [ toolchain crossMig ];

      # CFLAGS go via configureFlags (below), NOT a derivation env var: an env
      # CFLAGS is seen by configure (→ config.make) AND make, so `-g/-O/-std`
      # land in DW_AT_producer twice vs the in-tree build (configure-only).  The
      # toolchain debug-prefix-map moves to NIX_CFLAGS_COMPILE (preBuild) — the
      # in-tree dev shell's channel — so neither doubles.

      # Splice the eval-time-composed version into version.m4 before the
      # autoreconfHook regenerates configure.  ${fullVersion} is composed
      # from upstream-m4 + the gnumach-src input + flake.lock fork-id + self.
      postPatch = ''
        sed -i.bak \
          -e 's|m4_define(\[AC_PACKAGE_VERSION\],\[[^]]*\])|m4_define([AC_PACKAGE_VERSION],[${fullVersion}])|' \
          version.m4
        rm version.m4.bak
        grep AC_PACKAGE_VERSION version.m4
      '';

      # Native stdenv pins CC to the wrapped cross cc so configure's
      # AC_PROG_CC + AC_CHECK_TOOL resolve the `<cpu>-gnu` tools (on PATH
      # via `toolchain`) rather than the host gcc autoreconfHook adds.
      # gnumach's configure.ac forces `-ffreestanding -nostdlib`, so this
      # cc links the freestanding kernel with no libc.
      preConfigure = ''
        export CC=${tp}-gcc
        # CFLAGS via configureFlagsArray (a bash array) so the embedded space
        # survives — a plain configureFlags list element is word-split by nix.
        configureFlagsArray+=("CFLAGS=-g -O2")
        # Build OUT-OF-TREE with an ABSOLUTE srcdir, mirroring the in-tree build
        # (work/gnumach/… ≠ src/gnumach): an in-source build leaves unmapped
        # relative `../` paths in DWARF; absolute source paths map cleanly to
        # ${buildFlags.gnumachCanonBuild} (see preBuild) — matching the in-tree.
        srcdir="$PWD"
        mkdir -p "$NIX_BUILD_TOP/build"
        cd "$NIX_BUILD_TOP/build"
        configureScript="$srcdir/configure"
      '';

      # Force the cross binutils into the recursive sub-makes.  configure's
      # AC_CHECK_TOOL result doesn't always reach them, so on a non-Linux host
      # the built-in / host tools get used instead:
      #   AR/RANLIB/NM  host ar/ranlib can't index `<cpu>-gnu` ELF → empty
      #                 archives.
      #   LD            the kernel's relocatable link `$(LD) -u _start -r -o
      #                 gnumach.o …` (Makefile.am) otherwise runs darwin's
      #                 cctools ld on i686-gnu .a files → "ld: unknown
      #                 architecture / building for macOS".
      #   STRIP         used by Makerules.am; host strip can't read the ELF.
      # Command-line make vars override the built-ins and propagate down —
      # the same cross tools the dev shell exports (cross-toolchain/dev-shell.nix).
      makeFlags = [
        "AR=${tp}-ar" "RANLIB=${tp}-ranlib" "NM=${tp}-nm"
        "LD=${tp}-ld" "STRIP=${tp}-strip"
      ];

      # --prefix=$out comes from the native stdenv's generic configurePhase;
      # --host is ours (the kernel is cross-compiled).
      #
      # --enable-dependency-tracking: gnumach ships no explicit
      # BUILT_SOURCES, so automake's per-object .Po files are the only
      # mechanism teaching make the .defs → .server.h → .o cascade —
      # compile mach_port.c only after MIG generates mach_port.server.h.
      configureFlags =
        [ "--host=${tp}" "--enable-dependency-tracking" ]
        ++ lib.optional (target.platform != null) "--enable-platform=${target.platform}";

      # gnumach's build is parallel-safe (unlike the Hurd userland, whose top
      # Makefile races prog- vs lib-subdirs).  The MIG codegen ordering
      # (.defs → .server.h → .o) is handled by --enable-dependency-tracking
      # above, and the in-tree `make -j` build confirms it holds under
      # parallelism.  nixpkgs defaults this to false; set it so the nix kernel
      # build uses all cores like the in-tree one.
      enableParallelBuilding = true;

      # Disable the `--shrink-rpath` patchELF fixup hook.  Adding patchelf to
      # nativeBuildInputs (above, for the audit) also registers patchelf's
      # setup-hook, which would run `patchelf --shrink-rpath` on every output
      # ELF in fixupPhase.  We don't want that mutating the cross kernel's
      # RPATH — it's freestanding (-nostdlib) with no meaningful rpath anyway,
      # so the pass is pointless and we keep it off for output stability.
      # dontPatchELF guards ONLY this shrink hook; the audit-tmpdir check
      # still runs.
      dontPatchELF = true;

      # Keep the kernel's `-g` DWARF (the build sets -g; on i386/x86_64
      # $out/boot/gnumach IS the ELF).  Without this the stdenv fixup strip
      # hook would discard it — we want dist/ usable for gdb / addr2line.
      # gnumach's own build never strips by default (its `%.stripped` rule is
      # a separate explicit target).  Stripping, if ever wanted for a release,
      # is a dist-phase concern.
      dontStrip = true;

      # Disable nixpkgs' userland hardening on the freestanding kernel.  The
      # mkDerivation default (relro/bindnow/pie/…) makes ld page-align the RW
      # PT_LOAD (.data → a page boundary), whereas the in-tree dev-shell build
      # packs it right after the RO segment — a +0x1000-class layout shift that
      # relocates every absolute address (identical code, divergent bytes).  The
      # flags are inert/meaningless for a -nostdlib -ffreestanding kernel; turning
      # them off here (and NIX_HARDENING_ENABLE= in the in-tree recipe) makes both
      # links lay the kernel out identically.
      hardeningDisable = [ "all" ];

      # `make install` produces $out/boot/gnumach plus the public
      # headers + .defs.  stdenv's default buildPhase ("make")
      # handles the kernel link.
      installPhase = ''
        runHook preInstall
        make install
        runHook postInstall
      '';

      # On aarch64, gnumach's `make install` ships only $out/boot/gnumach
      # — a raw binary (objcopy -O binary, no ELF header) so qemu's
      # -kernel accepts it.  The link intermediate `gnumach.elf` is the
      # unstripped ELF with full DWARF, sitting in the build dir but
      # not picked up by `make install`.  Copy it alongside so gdb /
      # addr2line have something to work with, AND so the cross-host
      # hash comparison in the toolchain-sanity-check workflow has a
      # debug-info-bearing artefact to compare on aarch64 (the raw
      # binary alone strips the DWARF where most legitimate cross-host
      # determinism work happens via -fdebug-prefix-map above).
      #
      # On i386/x86_64 there is no gnumach.elf intermediate ($out/boot/
      # gnumach is already the unstripped ELF), so the `[ -f ]` guard
      # makes this a no-op there.
      postInstall = ''
        if [ -f gnumach.elf ] && [ ! -e $out/boot/gnumach.elf ]; then
          install -m 0644 gnumach.elf $out/boot/gnumach.elf
        fi
      '';

      # Kernel tests (`make check-mach`) need qemu + grub-mkrescue +
      # u-boot etc. on the build host, and they execute the kernel
      # under qemu — neither fits the nix sandbox.  Keep tests under
      # the parent Makefile's check-mach target until the sandbox
      # story is sorted.  TODO: revisit.
      doCheck = false;

      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU Mach microkernel for ${target.crossTarget}";
        platforms = platforms.all;
      };

      # Determinism — make the nix kernel BYTE-IDENTICAL to the in-tree build of
      # the same source (mirrors flakes/cross-toolchain/glibc.nix + the in-tree
      # Makefile recipe).  gnumach builds IN-SOURCE here, so $PWD is the one root
      # holding both source and generated files; map it to the SINGLE canonical the
      # in-tree out-of-tree build also maps its src+build dirs to (build-flags.nix
      # gnumachCanonBuild), so the DWARF paths agree.  Pin the shared -frandom-seed
      # (stripping the reproducible-builds hook's $out-derived, host-varying one
      # first — exactly as the dev-shell does for the in-tree build).  Replaces
      # helpers.mkReproAttrs (whose /build map + per-package seed don't match the
      # in-tree's canonical + shared seed).  debugPrefixMap (toolchain→/cross-gcc,
      # in CFLAGS) + dontStrip stay.
      preBuild = ''
        # mach.info's "last updated …" comes from the doc .texi FILE MTIME via
        # mdate-sh (which ignores SOURCE_DATE_EPOCH, despite its comment — true of
        # automake 1.18's mdate-sh too).  Set the mtime to the source commit date
        # so it's a MEANINGFUL date that matches the in-tree build (which touches
        # the same from `git log %ct`), not the store mtime=1 (1 Jan 1970).
        touch -d @${toString srcInput.lastModified} "$srcdir"/doc/*.texi
        export NIX_CFLAGS_COMPILE="$(printf %s "$NIX_CFLAGS_COMPILE" | sed -E 's/-frandom-seed=[^ ]*//g') ${buildFlags.debugPrefixMapStr toolchain} -ffile-prefix-map=$srcdir=${buildFlags.gnumachCanonBuild} -ffile-prefix-map=$PWD=${buildFlags.gnumachCanonBuild} -frandom-seed=${buildFlags.randomSeed}"
      '';
    });
in
lib.mapAttrs' (name: target: lib.nameValuePair "gnumach-${name}" (mkOne name target)) targets
