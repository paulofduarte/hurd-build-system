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
# Per-target attrset fields (mirrors flake.nix):
#   crossSystem : nixpkgs cross-system identifier ("i686-elf" etc.).
#                 Drives the cross-toolchain selection.
#   migTarget   : MIG-flavor triple ("i686-gnu" etc.).  Used to derive
#                 pname so each target's headers live in a distinct
#                 /nix/store path.
#   platform    : "at" / "xen" / null — fed to gnumach's
#                 --enable-platform= flag.  Null means the option is
#                 omitted (aarch64 has no platform).
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
    in
    crossPkgs.stdenv.mkDerivation {
      pname   = "gnumach-headers-${target.migTarget}";
      version = "src";

      # The pinned `gnumach-src` input (a github fork rev locked in
      # flake.lock) — never the local src/gnumach working clone.  Keeps the
      # built headers honest to flake.lock.
      src = srcInput;

      # Native build tools for autoreconf + configure.  Cross-stdenv's cc
      # already provides the target compiler that configure's checks need.
      # autoreconfHook supplies autoconf/automake/libtool/m4 and runs
      # autoreconf.  texinfo: `make install-data` builds doc/mach.info
      # (makeinfo).  No bison/flex/perl — install-data compiles nothing and
      # stubs MIG; awk comes from stdenv.
      nativeBuildInputs = [ pkgs.autoreconfHook pkgs.texinfo ];

      # GCC 15+ defaults to C23; matches the dev shell's pin.
      CFLAGS = "-std=gnu17 -g -O2";

      # USER_MIG is read by gnumach's tests/configfrag.ac via AC_CHECK_PROG.
      # install-data never invokes the binary, so a stub satisfies the check.
      preConfigure = ''
        export USER_MIG=/bin/true
      '';

      # --host and --prefix are injected by the cross-stdenv's configurePhase
      # (from $crossConfig and $prefix).  Only the platform flag is ours.
      configureFlags =
        lib.optional (target.platform != null) "--enable-platform=${target.platform}";

      # We only want the headers — skip the kernel build entirely.
      dontBuild = true;

      installPhase = ''
        runHook preInstall
        make install-data
        runHook postInstall
      '';

      # Expose the target attrset so downstream derivations (mig) can read
      # crossSystem/migTarget without re-deriving them.
      passthru = { inherit target; };

      meta = with lib; {
        description = "GNU Mach public headers for ${target.migTarget}";
        platforms = platforms.all;
      };
    };
in
lib.mapAttrs' (name: target: lib.nameValuePair "gnumach-headers-${name}" (mkOne name target)) targets
