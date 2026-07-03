# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# GNU Mach public headers - per-target derivations (autoreconf + configure +
# make install-data), one `gnumach-headers-<name>` per entry in `targets`.
# Output ($out/usr/include/...) is what downstream consumers (MIG cpu.sym, the
# kernel build) include.
#
# Output layout (gnumach's `make install-data`, FHS /usr):
#   $out/usr/include/mach/...        (public Mach RPC + type headers)
#   $out/usr/include/mach/<arch>/... (per-arch public headers)
#   $out/usr/share/...               (.defs files MIG can import, .msgids)
#
# Per-target attrset fields (see target-archs.nix + flake.nix):
#   crossTarget : nixpkgs cross-system config ("i686-gnu" etc.) - drives the
#                 cross-toolchain selection and the pname.
#   platform    : "at" / "xen" - fed to gnumach's --enable-platform= flag.
#
# Source comes from the pinned `gnumach-toolchain-src` flake input, NOT the local
# src/gnumach clone.
#
# Side-stepped concerns: install-data compiles no kernel objects, so the
# cross-toolchain only has to satisfy configure's compiler checks; USER_MIG
# (needed at configure for AC_CHECK_PROG, never invoked) points at /bin/true so
# the check passes without dragging MIG into the inputs.

{
  nixpkgs,
  system,
  targets,
  bootstrapGcc,
  # The cc that satisfies configure's AC_PROG_CC link test.  `install-data` compiles
  # NOTHING, so the choice is output-neutral - it only decides which cc lands in the
  # build closure.  Default = the libc-free bootstrap-gcc (the PRE-glibc bootstrap
  # variant, before cross-gcc exists).  The post-glibc alias overrides this to the
  # cached cross-gcc so these headers don't drag the uncached bootstrap-gcc into every
  # downstream consumer (mig, gnumach, hurd, hurd-stubs, the dev shell, dist).
  buildCC ? (name: _target: bootstrapGcc."bootstrap-gcc-${name}"),
  srcInput,
  # Ship include/ only - drop share/ (mach.info docs) from the output.  No
  # consumer reads it (glibc/mig compile against include/; the dist gets its
  # mach.info from the kernel package).
  includeOnly ? false,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  buildFlags = import ../cross-toolchain/build-flags.nix { inherit lib; };

  mkOne =
    name: target:
    let
      # The configure-check cc (see buildCC above).  install-data compiles nothing;
      # configure's AC_PROG_CC link test passes because gnumach's configure.ac forces
      # `-ffreestanding -nostdlib`, so no crt0/libc is needed (true for both the
      # libc-free bootstrap-gcc and the full cross-gcc).  The cc bakes
      # --with-as/--with-ld -> our cross-binutils, so it needs no binutils on PATH.
      cc = buildCC name target;
      tp = target.crossTarget;
    in
    pkgs.stdenv.mkDerivation (
      {
        pname = "gnumach-headers-${tp}";
        version = "src";

        # The pinned `gnumach-toolchain-src` input, never the local src/gnumach clone.
        src = srcInput;

        # autoreconfHook supplies autoconf/automake/libtool/m4.  texinfo: `make
        # install-data` builds doc/mach.info (makeinfo).  the buildCC provides
        # ${tp}-gcc for configure's checks.  No bison/flex/perl - install-data
        # compiles nothing and stubs MIG.
        nativeBuildInputs = [
          pkgs.autoreconfHook
          pkgs.texinfo
          cc
        ];

        CFLAGS = buildFlags.baseCflags;

        # Pin CC to the cross cc (host gcc would fail the --host=<cpu>-gnu
        # configure).  USER_MIG is read via AC_CHECK_PROG but never invoked by
        # install-data, so a stub satisfies the check.
        preConfigure = ''
          export CC=${tp}-gcc
          export USER_MIG=/bin/true
        '';

        # --host is ours (these are cross headers), plus the platform flag.
        configureFlags = [
          "--host=${tp}"
        ]
        ++ lib.optional (target.platform != null) "--enable-platform=${target.platform}";

        # We only want the headers - skip the kernel build entirely.
        dontBuild = true;

        # install-data -> $out/usr/include (+ /usr/share for mach.info): the FHS /usr
        # layout, matching glibc/hurd/gcc and the shipped gnumach.  configure's
        # --prefix=$out default puts includedir=$out/include; override to /usr/include.
        installPhase = ''
          runHook preInstall
          make install-data includedir=$out/usr/include datarootdir=$out/usr/share
          runHook postInstall
        '';

        # Expose the target attrset so downstream derivations (mig) can read
        # crossTarget.
        passthru = { inherit target; };

        meta = with lib; {
          description = "GNU Mach public headers for ${target.crossTarget}";
          platforms = platforms.all;
        };
      }
      // lib.optionalAttrs includeOnly { postInstall = ''rm -rf "$out/share"''; }
    );
in
lib.mapAttrs' (
  name: target: lib.nameValuePair "gnumach-headers-${name}" (mkOne name target)
) targets
