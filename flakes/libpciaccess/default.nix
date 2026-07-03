# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-built libpciaccess - per-userland-target derivations (rump-stack dep).
#
# Why it exists (RUMP-STACK-FEASIBILITY round-2): hurd's pci-arbiter is gated
# on PKG_CHECK_MODULES(pciaccess), the acpi translator and the rumpkernel both
# link -lpciaccess, and the .static boot servers need the static archive.
# The Hurd backend is upstream since 0.17 (hurd_pci.c talks to pci-arbiter via
# /servers/bus/pci; x86_pci.c does raw access for the arbiter itself) - no
# Debian fork needed.  0.17 is pinned deliberately: it is the last autotools
# release (0.18+ is meson-only), and configure selects the Hurd backends from
# --host=<cpu>-gnu.
#
# Layout mirrors the deploy-prefix policy: configure --prefix=/usr with the
# install landing in $out via DESTDIR, so every baked path (and pciaccess.pc's
# prefix) is deployable, not a store path.  NOTE for the hurd-config flip:
# consumers resolving pciaccess.pc from the store copy must remap that /usr
# prefix (pkg-config --define-prefix or PKG_CONFIG_SYSROOT_DIR).
# Source comes from the pinned `libpciaccess-src` flake input.

{
  nixpkgs,
  system,
  targets,
  toolchainFor,
  srcInput,
  zlib,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  helpers = import ../lib { inherit lib; };
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  version = helpers.parseAcInitVersion (srcInput + "/configure.ac");

  userlandTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;

  mkOne =
    name: target:
    let
      tp = target.crossTarget; # e.g. i686-gnu
      tc = toolchainFor target;
      inherit (tc) cc;
      binu = tc.binutils;
      zlibPkg = zlib."zlib-${name}";
    in
    pkgs.stdenv.mkDerivation {
      pname = "libpciaccess-${tp}";
      inherit version;
      src = srcInput;

      # Upstream 6cd5a4afbb70 (post-0.17): hurd_pci.c passes size_t* where the
      # Mach RPCs want mach_msg_type_number_t* - equal widths on i686, a hard
      # incompatible-pointer error on x86_64-gnu.  0.18 ships the fix but is
      # meson-only, so 0.17 + this backport.
      patches = [ ./patches/00-hurd-amd64-mach-msg-type-number.patch ];

      # Shipped configure (upstream release tarball) - no autoreconf, fewer
      # build deps and upstream-blessed.  patchelf: darwin's audit-tmpdir
      # fixup (same as flakes/hurd).
      nativeBuildInputs = [
        cc
        binu
        pkgs.patchelf
      ];

      # CC pinned to the cross tool; zlib (our cross-built one) via explicit
      # CPPFLAGS/LDFLAGS - it lives at $out/usr/{include,lib}, outside the
      # sysroot, so configure's zlib probe needs the paths spelled out.  The
      # determinism maps ride the same CPPFLAGS export (appended after, both
      # end up in the configure-baked flags).
      preConfigure = ''
        export CC=${tp}-gcc
        export AR=${tp}-ar
        export RANLIB=${tp}-ranlib
        # LD/NM explicitly the cross ones: libtool's "ld used by ${tp}-gcc" probe
        # otherwise lands on the HOST ld (Mach-O on darwin) -> "linker supports
        # shared libraries... no" -> only the static archive gets built.
        export LD=${tp}-ld
        export NM=${tp}-nm
        srcdir=$PWD
        ${buildFlags.detCppflagsUnwrapped {
          gcc = cc;
          binutils = binu;
          canonBuild = "/libpciaccess-build";
          inherit (tc) sysroot;
        }}
        export CPPFLAGS="$CPPFLAGS -I${zlibPkg}/usr/include -ffile-prefix-map=${zlibPkg}=/zlib"
        export LDFLAGS="-L${zlibPkg}/usr/lib ''${LDFLAGS:-}"
        # --with-zlib probes via PKG_CHECK_MODULES; ZLIB_CFLAGS/ZLIB_LIBS are its
        # documented escape hatch - set both so no pkg-config (and no .pc prefix
        # remapping) is needed at all.  ZLIB_LIBS deliberately has NO -L: it is
        # copied verbatim into pciaccess.pc's Libs.private, which must stay
        # deployable (libz lives in the same target /usr/lib); the build-time -L
        # rides LDFLAGS above instead.
        export ZLIB_CFLAGS="-I${zlibPkg}/usr/include"
        export ZLIB_LIBS="-lz"
        configureFlagsArray+=("CFLAGS=${buildFlags.baseCflags}")
      '';

      # --enable-static: the .static boot servers (pci-arbiter.static,
      # rumpdisk.static) link libpciaccess.a with --whole-archive.
      # --with-zlib: read gzip'd pci.ids (Debian parity).
      configureFlags = [
        "--host=${tp}"
        "--prefix=/usr"
        "--enable-static"
        "--with-zlib"
      ];
      dontAddPrefix = true;

      enableParallelBuilding = true;

      installPhase = ''
        runHook preInstall
        make install DESTDIR=$out
        runHook postInstall
      '';

      # Drop the libtool archive: libtool-only metadata that bakes the
      # build-time store -L (zlib) into dependency_libs - not deployable, and
      # nothing links via libtool on the target (Debian policy drops .la too).
      postInstall = ''
        rm -f $out/usr/lib/*.la
      '';

      # Same output-hygiene set as the hurd userland: keep DWARF for the dist
      # dbg split, no rpath shrinking, no store-path shebangs.
      dontPatchELF = true;
      dontStrip = true;
      dontPatchShebangs = true;

      passthru = { inherit target; };
      meta = with lib; {
        description = "libpciaccess for ${tp} (pci-arbiter/acpi/rumpkernel dep)";
        platforms = platforms.all;
        license = licenses.mit;
      };
    };
in
lib.mapAttrs' (
  name: target: lib.nameValuePair "libpciaccess-${name}" (mkOne name target)
) userlandTargets
