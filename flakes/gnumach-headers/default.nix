# GNU Mach public headers — per-target derivations.
#
# One nix derivation per target (autoreconf + configure + make
# install-data) whose output ($out/include/...) is what downstream
# consumers (MIG cpu.sym, the kernel build itself) include.
#
# Output layout (whatever gnumach's `make install-data` produces, which
# at minimum is):
#   $out/include/mach/...        (public Mach RPC + type headers)
#   $out/include/mach/<arch>/... (per-arch public headers — i386, x86_64,
#                                 aarch64 etc.)
#   $out/share/...               (.defs files MIG can import, .msgids)
#
# Returned shape — one attribute per entry in `targets`, named
# `gnumach-headers-<name>`.  The root flake just merges what comes back
# into `packages.<system>`.
#
# Per-target attrset fields (see target-archs.nix + flake.nix):
#   crossTarget : nixpkgs cross-system config ("i686-gnu" etc.).  Drives
#                 the cross-toolchain selection and the pname (so each
#                 target's headers get a distinct /nix/store path).
#   platform    : "at" / "xen" — fed to gnumach's --enable-platform= flag.
#
# Source comes from the pinned `gnumach-src` flake input (a github fork rev
# locked in flake.lock; see flake.nix + flakes/sources), NOT the local
# src/gnumach working clone.
#
# Side-stepped concerns:
#   - install-data doesn't compile any actual kernel objects, so the
#     cross-toolchain only has to satisfy configure's compiler checks.
#   - USER_MIG must be set at configure time for AC_CHECK_PROG, but is
#     never invoked during install-data; point it at /bin/true so the
#     check passes without dragging MIG into this derivation's inputs.

{ nixpkgs, system, targets, mkCrossPkgs, srcInput }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;

  mkOne = name: target:
    let
      crossPkgs = mkCrossPkgs system target;
      # The libc-free stage-1 cc (gccWithoutTargetLibc): the `<cpu>-gnu`
      # cross stdenv's own `.cc` would pull nixpkgs' meta-gated glibc, and
      # the headers precede glibc-hurd in the bootstrap so no libc exists
      # yet anyway.  install-data compiles nothing; configure's AC_PROG_CC
      # link test passes because gnumach's configure.ac forces
      # `-ffreestanding -nostdlib`, so no crt0/libc is needed.
      cc = crossPkgs.buildPackages.gccWithoutTargetLibc;
      tp = target.crossTarget;
    in
    pkgs.stdenv.mkDerivation {
      pname   = "gnumach-headers-${tp}";
      version = "src";

      # The pinned `gnumach-src` input (a github fork rev locked in
      # flake.lock) — never the local src/gnumach working clone.  Keeps the
      # built headers honest to flake.lock.
      src = srcInput;

      # autoreconfHook supplies autoconf/automake/libtool/m4 and runs
      # autoreconf.  texinfo: `make install-data` builds doc/mach.info
      # (makeinfo).  The stage-1 cc provides ${tp}-gcc for configure's
      # checks.  No bison/flex/perl — install-data compiles nothing and
      # stubs MIG; awk comes from stdenv.
      nativeBuildInputs = [ pkgs.autoreconfHook pkgs.texinfo cc ];

      CFLAGS = "-g -O2";

      # Native stdenv: pin CC to the stage-1 cross cc (host gcc would fail
      # the --host=<cpu>-gnu configure).  USER_MIG is read by gnumach's
      # tests/configfrag.ac via AC_CHECK_PROG; install-data never invokes
      # the binary, so a stub satisfies the check.
      preConfigure = ''
        export CC=${tp}-gcc
        export USER_MIG=/bin/true
      '';

      # --prefix=$out comes from the native stdenv's configurePhase; --host
      # is ours (these are cross headers).  Plus the platform flag.
      configureFlags =
        [ "--host=${tp}" ]
        ++ lib.optional (target.platform != null) "--enable-platform=${target.platform}";

      # We only want the headers — skip the kernel build entirely.
      dontBuild = true;

      installPhase = ''
        runHook preInstall
        make install-data
        runHook postInstall
      '';

      # Expose the target attrset so downstream derivations (mig) can read
      # crossTarget without re-deriving it.
      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU Mach public headers for ${target.crossTarget}";
        platforms = platforms.all;
      };
    };
in
lib.mapAttrs' (name: target: lib.nameValuePair "gnumach-headers-${name}" (mkOne name target)) targets
