# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# GNU Mach public headers - per-target derivations (autoreconf + configure +
# make install-data), one `gnumach-headers-<name>` per entry in `targets`.
# Output ($out/include/...) is what downstream consumers (MIG cpu.sym, the
# kernel build) include.
#
# Output layout (gnumach's `make install-data`):
#   $out/include/mach/...        (public Mach RPC + type headers)
#   $out/include/mach/<arch>/... (per-arch public headers)
#   $out/share/...               (.defs files MIG can import, .msgids)
#
# Per-target attrset fields (see target-archs.nix + flake.nix):
#   crossTarget : nixpkgs cross-system config ("i686-gnu" etc.) - drives the
#                 cross-toolchain selection and the pname.
#   platform    : "at" / "xen" - fed to gnumach's --enable-platform= flag.
#
# Source comes from the pinned `gnumach-src` flake input, NOT the local
# src/gnumach clone.
#
# Side-stepped concerns: install-data compiles no kernel objects, so the
# cross-toolchain only has to satisfy configure's compiler checks; USER_MIG
# (needed at configure for AC_CHECK_PROG, never invoked) points at /bin/true so
# the check passes without dragging MIG into the inputs.

{ nixpkgs, system, targets, mkCrossPkgs, srcInput }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  mkOne = name: target:
    let
      crossPkgs = mkCrossPkgs system target;
      # The libc-free bootstrap-gcc (gccWithoutTargetLibc) - the `<cpu>-gnu` cross
      # stdenv's own `.cc` would pull nixpkgs' meta-gated glibc.  install-data
      # compiles nothing; configure's AC_PROG_CC link test passes because
      # gnumach's configure.ac forces `-ffreestanding -nostdlib`, so no crt0/libc
      # is needed.
      cc = crossPkgs.buildPackages.gccWithoutTargetLibc;
      tp = target.crossTarget;
    in
    pkgs.stdenv.mkDerivation {
      pname   = "gnumach-headers-${tp}";
      version = "src";

      # The pinned `gnumach-src` input, never the local src/gnumach clone.
      src = srcInput;

      # autoreconfHook supplies autoconf/automake/libtool/m4.  texinfo: `make
      # install-data` builds doc/mach.info (makeinfo).  bootstrap-gcc provides
      # ${tp}-gcc for configure's checks.  No bison/flex/perl - install-data
      # compiles nothing and stubs MIG.
      nativeBuildInputs = [ pkgs.autoreconfHook pkgs.texinfo cc ];

      CFLAGS = buildFlags.baseCflags;

      # Pin CC to the bootstrap-gcc cross cc (host gcc would fail the --host=<cpu>-gnu
      # configure).  USER_MIG is read via AC_CHECK_PROG but never invoked by
      # install-data, so a stub satisfies the check.
      preConfigure = ''
        export CC=${tp}-gcc
        export USER_MIG=/bin/true
      '';

      # --host is ours (these are cross headers), plus the platform flag.
      configureFlags =
        [ "--host=${tp}" ]
        ++ lib.optional (target.platform != null) "--enable-platform=${target.platform}";

      # We only want the headers - skip the kernel build entirely.
      dontBuild = true;

      installPhase = ''
        runHook preInstall
        make install-data
        runHook postInstall
      '';

      # Expose the target attrset so downstream derivations (mig) can read
      # crossTarget.
      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU Mach public headers for ${target.crossTarget}";
        platforms = platforms.all;
      };
    };
in
lib.mapAttrs' (name: target: lib.nameValuePair "gnumach-headers-${name}" (mkOne name target)) targets
