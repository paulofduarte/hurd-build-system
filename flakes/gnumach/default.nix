# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# GNU Mach kernel - per-target derivations (autoreconf + configure + make +
# make install), one `gnumach-<name>` per entry in `targets`.
#
# Output layout:
#   $out/boot/gnumach              bootable kernel - raw binary (objcopy -O
#                                  binary) on aarch64 so qemu's -kernel accepts
#                                  it, ELF with debug info on i386/x86_64.
#   $out/boot/gnumach.elf          unstripped ELF with DWARF - aarch64 only
#                                  (paired with the raw binary for gdb).
#   $out/include/mach/...          public headers.
#   $out/share/...                 .defs + .msgids.
#
# Per-target attrset fields (see target-archs.nix + flake.nix):
#   crossTarget : nixpkgs cross-system config (`<cpu>-gnu`) - drives the
#                 wrapped cross toolchain, the pname, and the cross-MIG lookup.
#   platform    : "at" / "xen" - fed to gnumach's --enable-platform= flag.
#
# Source comes from the pinned `gnumach-src` flake input, NOT the local
# src/gnumach working clone (a `make src` dev convenience).
#
# `mig` is the attrset from flakes/mig; "mig-<name>" goes into nativeBuildInputs.
# gnumach's configure runs `AC_CHECK_TOOL([MIG], [mig])` + `AC_CHECK_PROG(
# [USER_MIG], [<crossTarget>-mig])`; the mig sub-flake ships both the primary
# `<crossTarget>-mig` binary AND a `<crossPrefix>mig` alias, so both checks
# self-discover via PATH with no `MIG=` override here.
#
# doCheck = false: the `make check-mach` harness assumes the in-repo work/ tree
# + a host qemu, which the sandbox can't provide; tests stay under the parent
# Makefile's check-mach target.

{ nixpkgs, system, targets, mig, toolchainFor, self, srcInput, forkUrl, buildRevToken ? null }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  # Upstream version parsed from version.m4 (AC_PACKAGE_VERSION).
  upstreamVersion = helpers.parseM4Version (srcInput + "/version.m4");

  # PACKAGE_VERSION composed at eval time - see flakes/lib (composeVersion).
  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self forkUrl buildRevToken;
  };

  mkOne = name: target:
    let
      crossMig  = mig."mig-${name}";
      tp        = target.crossTarget;                 # e.g. i686-gnu
      # The from-source toolchain: the unwrapped cross-gcc + cross-binutils (the same
      # cross-gcc-<arch> the userland uses).  The kernel builds freestanding
      # (configure.ac forces -ffreestanding -nostdlib) so glibc-hurd is never linked;
      # the cross-gcc's baked sysroot is inert for -nostdlib.  Native stdenv: cross
      # tools come in by name (on PATH) below.
      tc        = toolchainFor target;
      cc        = tc.cc;          # cross-gcc-<arch>      (provides ${tp}-gcc/-g++)
      binu      = tc.binutils;    # cross-binutils-<arch> (provides ${tp}-ar/-ld/...)
      pname     = "gnumach-${tp}";
    in
    pkgs.stdenv.mkDerivation ({
      inherit pname;

      # Drives both the store path suffix and (via the sed below) the
      # binary's PACKAGE_VERSION - same string, traceable on both sides.
      version = fullVersion;

      # The pinned `gnumach-src` input, never the local src/gnumach clone, so the
      # built bytes match the version string's `srcInput.shortRev`.
      src = srcInput;

      # autoreconfHook supplies autoconf/automake/libtool/m4.  texinfo: the build
      # runs makeinfo (mach.info).  perl: the MIG wrapper shells out to perl.  The
      # wrapped cross cc (${tp}-gcc + cross binutils) + cross mig (${tp}-mig) are
      # found by configure's host-prefixed tool search; CC is pinned below.
      # patchelf: the stdenv audit-tmpdir fixup runs `patchelf --print-rpath` on
      # each output ELF to verify no $TMPDIR path leaked into RPATH; the default
      # darwin stdenv ships no patchelf, so add it (a no-op for the freestanding
      # kernel, but the audit runs honestly).  dontPatchELF below disables
      # patchelf's OTHER hook (--shrink-rpath).
      nativeBuildInputs =
        [ pkgs.autoreconfHook ]
        ++ (with pkgs; [ texinfo perl patchelf ])
        ++ [ cc binu crossMig ];

      # CFLAGS go via configureFlags (below), NOT a derivation env var: an env
      # CFLAGS is seen by configure (-> config.make) AND make, so `-g/-O/-std`
      # land in DW_AT_producer twice vs the in-tree build (configure-only).  The
      # toolchain debug-prefix-map moves to NIX_CFLAGS_COMPILE (preBuild).

      # Splice the composed version into version.m4 before autoreconfHook
      # regenerates configure.
      postPatch = ''
        sed -i.bak \
          -e 's|m4_define(\[AC_PACKAGE_VERSION\],\[[^]]*\])|m4_define([AC_PACKAGE_VERSION],[${fullVersion}])|' \
          version.m4
        rm version.m4.bak
        grep AC_PACKAGE_VERSION version.m4
      '';

      # Pin CC to the wrapped cross cc so configure's AC_PROG_CC + AC_CHECK_TOOL
      # resolve the `<cpu>-gnu` tools rather than the host gcc autoreconfHook adds.
      preConfigure = ''
        export CC=${tp}-gcc
        # CFLAGS via configureFlagsArray (a bash array) so the embedded space
        # survives - a plain configureFlags list element is word-split by nix.
        configureFlagsArray+=("CFLAGS=${buildFlags.baseCflags}")
        ${helpers.crossPkg.outOfTreePreConfigure}
        # Determinism maps via CPPFLAGS (the raw cross-gcc ignores the wrapper's
        # NIX_CFLAGS_COMPILE).  Set AFTER outOfTreePreConfigure so $srcdir is defined
        # and configure bakes it; maps the gcc+binutils store paths + $srcdir/$PWD.
        ${buildFlags.detCppflagsUnwrapped { gcc = cc; binutils = binu; canonBuild = buildFlags.gnumachCanonBuild; }}
      '';

      # Force the cross binutils into the recursive sub-makes - configure's
      # AC_CHECK_TOOL result doesn't always reach them, so on a non-Linux host
      # the host tools get used instead:
      #   AR/RANLIB/NM  host ar/ranlib can't index `<cpu>-gnu` ELF -> empty
      #                 archives.
      #   LD            the relocatable link `$(LD) -u _start -r -o gnumach.o ...`
      #                 otherwise runs darwin's cctools ld on i686-gnu .a files.
      #   STRIP         host strip can't read the ELF.
      # Command-line make vars override the built-ins and propagate down.
      makeFlags = [
        "AR=${tp}-ar" "RANLIB=${tp}-ranlib" "NM=${tp}-nm"
        "LD=${tp}-ld" "STRIP=${tp}-strip"
      ];

      # --host is ours (the kernel is cross-compiled).  --enable-dependency-
      # tracking: gnumach ships no explicit BUILT_SOURCES, so automake's
      # per-object .Po files are the only thing teaching make the .defs ->
      # .server.h -> .o cascade (compile mach_port.c only after MIG generates
      # mach_port.server.h).
      configureFlags =
        [ "--host=${tp}" "--enable-dependency-tracking" ]
        ++ lib.optional (target.platform != null) "--enable-platform=${target.platform}";

      # gnumach's build is parallel-safe (unlike the Hurd userland); the MIG
      # codegen ordering is handled by --enable-dependency-tracking above.
      # nixpkgs defaults this to false; set it to use all cores.
      enableParallelBuilding = true;

      # Disable the `--shrink-rpath` patchELF hook (registered by the patchelf
      # in nativeBuildInputs).  No point mutating the freestanding kernel's
      # (meaningless) RPATH; keep it off for output stability.  dontPatchELF
      # guards ONLY this hook; the audit-tmpdir check still runs.
      dontPatchELF = true;

      # Keep the kernel's `-g` DWARF (on i386/x86_64 $out/boot/gnumach IS the
      # ELF); the stdenv fixup strip hook would otherwise discard it.  Stripping
      # is a dist-phase concern.
      dontStrip = true;

      # Disable nixpkgs' userland hardening on the freestanding kernel.  The
      # default (relro/bindnow/pie/...) makes ld page-align the RW PT_LOAD, whereas
      # the in-tree dev-shell build packs it right after the RO segment - a
      # +0x1000-class layout shift that relocates every absolute address
      # (identical code, divergent bytes).  The flags are inert for a -nostdlib
      # -ffreestanding kernel; off here (+ NIX_HARDENING_ENABLE= in-tree) makes
      # both links lay out identically.
      hardeningDisable = [ "all" ];

      # `make install` produces $out/boot/gnumach plus the public headers +
      # .defs.  stdenv's default buildPhase handles the kernel link.
      installPhase = ''
        runHook preInstall
        make install
        runHook postInstall
      '';

      # On aarch64, `make install` ships only $out/boot/gnumach - a raw binary
      # (objcopy -O binary, no ELF header) so qemu's -kernel accepts it.  The
      # link intermediate `gnumach.elf` (unstripped ELF with DWARF) sits in the
      # build dir un-installed; copy it alongside so gdb/addr2line work AND the
      # cross-host hash check has a debug-info-bearing artefact to compare.  On
      # i386/x86_64 there's no gnumach.elf ($out/boot/gnumach is already the
      # ELF), so the `[ -f ]` guard makes this a no-op.
      postInstall = ''
        if [ -f gnumach.elf ] && [ ! -e $out/boot/gnumach.elf ]; then
          install -m 0644 gnumach.elf $out/boot/gnumach.elf
        fi
      '';

      # `make check-mach` needs qemu + grub-mkrescue + u-boot and runs the kernel
      # under qemu - neither fits the sandbox.  Tests run under the parent
      # Makefile's check-mach target instead.
      doCheck = false;

      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU Mach microkernel for ${target.crossTarget}";
        platforms = platforms.all;
      };

      # mach.info's "last updated ..." date comes from the doc .texi FILE MTIME via
      # mdate-sh (which ignores SOURCE_DATE_EPOCH, despite its comment - true of
      # automake 1.18's mdate-sh too).  Set the mtime to the source commit date so it's
      # a MEANINGFUL, reproducible date, not the store mtime=1 (1 Jan 1970).  (The DWARF
      # determinism maps live in CPPFLAGS, set in preConfigure.)
      preBuild = ''
        touch -d @${toString srcInput.lastModified} "$srcdir"/doc/*.texi
      '';
    });
in
lib.mapAttrs' (name: target: lib.nameValuePair "gnumach-${name}" (mkOne name target)) targets
