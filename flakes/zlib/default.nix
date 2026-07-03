# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-built target zlib - per-userland-target derivations (rump-stack dep).
#
# Why it exists (RUMP-STACK-FEASIBILITY round-2): hurd's rumpdisk links `-lz`
# unconditionally and libpciaccess reads compressed pci.ids via zlib, but the
# hurd build currently passes --without-libz because the sysroot carries no
# target zlib.  This is that target zlib: built with the from-source unwrapped
# cross toolchain against the glibc-hurd sysroot, usr-merged layout
# ($out/usr/{include,lib}), shared + static in one pass (libz.so + libz.a -
# the .static servers need the archive).
#
# zlib's hand-rolled configure (not autoconf) cross-compiles via the CHOST/CC
# environment, not --host; --prefix=/usr keeps every baked path deployable and
# install lands in $out via DESTDIR (mirrors the hurd/glibc deploy-prefix
# policy).  Source comes from the pinned `zlib-src` flake input.

{
  nixpkgs,
  system,
  targets,
  toolchainFor,
  srcInput,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  # Upstream version from zlib.h's ZLIB_VERSION define (pure eval).  Matched
  # over only the first 4KB (the define sits at byte ~1476): builtins.match is
  # a recursive std::regex, and backtracking over the whole 100KB header can
  # stack-overflow the Linux nix binary at eval time (it DID for libacpica's
  # unbounded twin of this parse).
  version =
    let
      match = builtins.match ".*#define ZLIB_VERSION \"([0-9.]+)\".*" (
        builtins.substring 0 4096 (builtins.readFile (srcInput + "/zlib.h"))
      );
    in
    if match == null then "unknown" else builtins.head match;

  userlandTargets = lib.filterAttrs (_: t: (t.platform or null) != "xen") targets;

  mkOne =
    _name: target:
    let
      tp = target.crossTarget; # e.g. i686-gnu
      tc = toolchainFor target;
      inherit (tc) cc;
      binu = tc.binutils;
    in
    pkgs.stdenv.mkDerivation {
      pname = "zlib-${tp}";
      inherit version;
      src = srcInput;

      # patchelf: darwin's stdenv audit-tmpdir fixup needs it for the shared lib
      # (same reasoning as flakes/hurd).
      nativeBuildInputs = [
        cc
        binu
        pkgs.patchelf
      ];

      # zlib's configure reads the toolchain from the environment: CHOST selects
      # the cross prefix, and AR/RANLIB/NM must be the cross ones or the static
      # archive is indexed by the host tools (unusable for i686/x86_64-gnu on a
      # non-Linux host).  CFLAGS baseline matches the repo-wide "-g -O2"; the
      # determinism maps ride CPPFLAGS (the raw cross-gcc has no wrapper
      # channel).  srcdir=$PWD: zlib builds in-tree, so the single canon map
      # covers both roots.
      preConfigure = ''
        export CHOST=${tp}
        export CC=${tp}-gcc
        export AR=${tp}-ar
        export RANLIB=${tp}-ranlib
        export NM=${tp}-nm
        export CFLAGS="${buildFlags.baseCflags}"
        srcdir=$PWD
        ${buildFlags.detCppflagsUnwrapped {
          gcc = cc;
          binutils = binu;
          canonBuild = "/zlib-build";
          inherit (tc) sysroot;
        }}
      '';

      # Deployable prefix (see header comment); DESTDIR install below.
      dontAddPrefix = true;
      configureFlags = [ "--prefix=/usr" ];
      # zlib's configure is not autoconf: no --build/--host support, and it
      # must not be handed stdenv's default cross flags.
      dontDisableStatic = true;

      enableParallelBuilding = true;

      installPhase = ''
        runHook preInstall
        make install DESTDIR=$out
        runHook postInstall
      '';

      # Same output-hygiene set as the hurd userland: keep DWARF for the dist
      # dbg split, no rpath shrinking, no store-path shebangs.
      dontPatchELF = true;
      dontStrip = true;
      dontPatchShebangs = true;

      passthru = { inherit target; };
      meta = with lib; {
        description = "zlib for ${tp} (rump-stack target dep)";
        platforms = platforms.all;
        license = licenses.zlib;
      };
    };
in
lib.mapAttrs' (name: target: lib.nameValuePair "zlib-${name}" (mkOne name target)) userlandTargets
