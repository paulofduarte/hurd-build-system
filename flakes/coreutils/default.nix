# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-built GNU coreutils - per-userland-target derivations (phase-2 base
# userland).  ls/cp/mkdir/cat/... for the self-built bootable system: hurd's
# rc and every interactive session assume the core utilities exist.
#
# Coreutils on GNU/Hurd is supported upstream (Debian builds it natively);
# cross-compiling the release tarball needs no Hurd patches - gnulib's
# configure answers its run-test guesses conservatively but correctly for a
# glibc target, and the man pages ship pre-generated in the tarball (they are
# normally rebuilt with help2man by RUNNING the tools, which a cross build
# cannot - the dist copies keep them current enough).
#
# Optional libs (gmp/acl/attr/selinux/libcap) are absent from the sysroot ->
# configure auto-disables them (expr/factor fall back to the non-GMP paths,
# ls drops ACL decoration) - matching a minimal bootstrap userland.
#
# Layout mirrors the deploy-prefix policy: --prefix=/usr, install via
# DESTDIR=$out.  Source = the pinned `coreutils-dep-src` release tarball.

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

  # Release tarballs carry the version in .tarball-version (AC_INIT calls
  # git-version-gen, which reads it back).
  version = lib.removeSuffix "\n" (builtins.readFile (srcInput + "/.tarball-version"));

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
      pname = "coreutils-${tp}";
      inherit version;
      src = srcInput;

      # Shipped configure (release tarball) - no autoreconf.  patchelf:
      # darwin's audit-tmpdir fixup (same as flakes/hurd).
      nativeBuildInputs = [
        cc
        binu
        pkgs.patchelf
      ];

      preConfigure = ''
        export CC=${tp}-gcc
        export AR=${tp}-ar
        export RANLIB=${tp}-ranlib
        srcdir=$PWD
        ${buildFlags.detCppflagsUnwrapped {
          gcc = cc;
          binutils = binu;
          canonBuild = "/coreutils-build";
          inherit (tc) sysroot;
        }}
        configureFlagsArray+=("CFLAGS=${buildFlags.baseCflags}")
      '';

      # --disable-year2038: Hurd's i386 glibc has no 64-bit time_t yet
      # (_TIME_BITS=64 is unsupported there), and gnulib otherwise hard-fails
      # ("could not enable timestamps after mid-January 2038").  Debian
      # hurd-i386 opts out the same way; on x86_64 time_t is natively 64-bit
      # and the flag is a no-op.
      configureFlags = [
        "--host=${tp}"
        "--prefix=/usr"
        "--disable-year2038"
      ];
      dontAddPrefix = true;

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
        description = "GNU coreutils for ${tp} (self-built system base userland)";
        platforms = platforms.all;
        license = licenses.gpl3Plus;
      };
    };
in
lib.mapAttrs' (
  name: target: lib.nameValuePair "coreutils-${name}" (mkOne name target)
) userlandTargets
