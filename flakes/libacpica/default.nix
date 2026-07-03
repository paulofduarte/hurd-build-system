# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-built libacpica - per-userland-target derivations (rump-stack dep).
#
# Why it exists (RUMP-STACK-FEASIBILITY round-2): hurd's acpi translator is
# gated on AC_CHECK_HEADER(acpi/acpi_init.h) and links -lacpica, and the
# rumpdisk boot chain runs acpi.static between pci-arbiter and rumpdisk.
# Source = Intel ACPICA (20220331) repackaged as a LIBRARY by the Debian Hurd
# team (salsa hurd-team/libacpica, the `libacpica-dep-src` pin): the repo
# carries the ACPICA drivers/ + include/ subset and quilt patches with the
# Hurd glue - acgnu.diff (GNU/Hurd platform header), acpi_init/global_state
# glue, and add-makefile.diff, which contributes the ENTIRE build system (a
# plain Makefile: libacpica.a + libacpica.so.0, install to
# $(PREFIX)/include/acpi + $(libdir)).
#
# Cross specifics: the Makefile honours CC/CFLAGS/LDFLAGS/PREFIX/libdir (and
# the implicit .c.o rule reads CPPFLAGS), but the archive rule hardcodes
# `ar crs` - postPatch rewrites it to $(AR) so the cross archiver indexes the
# x86-gnu objects (the host ar can't, same class of fix as flakes/hurd's
# makeFlags).  Links -lpciaccess -lirqhelp -lpthread: our cross libpciaccess
# + the libirqhelp pre-pass, wired via LDFLAGS -L; no rpath is baked (raw
# cross ld), so the DT_NEEDEDs resolve from /usr/lib on the target.
# Usr-merged deployable layout via PREFIX=/usr + DESTDIR=$out.

{
  nixpkgs,
  system,
  targets,
  toolchainFor,
  srcInput,
  libpciaccess,
  libirqhelp,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  # Upstream version from ACPICA's own ACPI_CA_VERSION define (pure eval;
  # 0x20220331 -> "20220331").  The match runs over only the file's first 2KB
  # (the define sits at byte ~441): nix's builtins.match is a recursive
  # std::regex, and a backtracking pattern over the whole 31KB header
  # stack-overflows the Linux nix binary (eval-time SEGV; darwin survives on
  # stack-size luck).  Bounding the haystack removes the blowup entirely.
  version =
    let
      match = builtins.match ".*#define ACPI_CA_VERSION[ \t]+0x([0-9A-Fa-f]+).*" (
        builtins.substring 0 2048 (builtins.readFile (srcInput + "/include/acpi/acpixf.h"))
      );
    in
    if match == null then "unknown" else builtins.head match;

  userlandTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;

  mkOne =
    name: target:
    let
      tp = target.crossTarget; # e.g. i686-gnu
      tc = toolchainFor target;
      inherit (tc) cc;
      binu = tc.binutils;
      pciPkg = libpciaccess."libpciaccess-${name}";
      irqPkg = libirqhelp."libirqhelp-${name}";
    in
    pkgs.stdenv.mkDerivation {
      pname = "libacpica-${tp}";
      inherit version;
      src = srcInput;

      # patchelf: darwin's stdenv audit-tmpdir fixup (same as flakes/hurd).
      nativeBuildInputs = [
        cc
        binu
        pkgs.patchelf
      ];

      # The Hurd glue arrives as the repo's own quilt series (the Makefile
      # itself is one of the patches).
      patchPhase = ''
        runHook prePatch
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          echo "applying debian/patches/$p"
          patch -p1 < "debian/patches/$p"
        done < debian/patches/series
        runHook postPatch
      '';

      # `ar crs` -> `$(AR) crs`: the literal host ar can't index ${tp} ELF on
      # a non-Linux host (empty archive, same failure class flakes/hurd pins
      # AR/RANLIB for).
      postPatch = ''
        sed -i.bak 's|^\tar crs |\t$(AR) crs |' Makefile
        rm Makefile.bak
        grep -n 'AR) crs' Makefile
      '';

      # No configure - a plain Makefile build.  CFLAGS matches the repo-wide
      # baseline (the Makefile appends its own -D__KERNEL__/-I set to it); the
      # determinism maps ride CPPFLAGS (implicit-rule channel); LDFLAGS wires
      # our cross libpciaccess + libirqhelp for the .so link.
      dontConfigure = true;
      preBuild = ''
        export CC=${tp}-gcc
        export AR=${tp}-ar
        export CFLAGS="${buildFlags.baseCflags}"
        srcdir=$PWD
        ${buildFlags.detCppflagsUnwrapped {
          gcc = cc;
          binutils = binu;
          canonBuild = "/libacpica-build";
          inherit (tc) sysroot;
        }}
        export LDFLAGS="-L${pciPkg}/usr/lib -L${irqPkg}/usr/lib"
        export CPPFLAGS="$CPPFLAGS -I${pciPkg}/usr/include -I${irqPkg}/usr/include -ffile-prefix-map=${pciPkg}=/libpciaccess -ffile-prefix-map=${irqPkg}=/libirqhelp"
      '';
      makeFlags = [
        "PREFIX=/usr"
        "libdir=/usr/lib"
      ];
      enableParallelBuilding = true;

      installPhase = ''
        runHook preInstall
        make install DESTDIR=$out $makeFlags
        runHook postInstall
      '';

      # Same output-hygiene set as the other rump-stack libs.
      dontPatchELF = true;
      dontStrip = true;
      dontPatchShebangs = true;

      passthru = { inherit target; };
      meta = with lib; {
        description = "Intel ACPICA as a library for ${tp} (hurd acpi/rumpdisk chain dep)";
        platforms = platforms.all;
        # Intel ACPICA is dual GPL-2.0/Intel-BSD; the Hurd glue (Makefile,
        # acpi_init) is GPL-2.0-or-later.
        license = with licenses; [
          gpl2Plus
          bsd3
        ];
      };
    };
in
lib.mapAttrs' (
  name: target: lib.nameValuePair "libacpica-${name}" (mkOne name target)
) userlandTargets
