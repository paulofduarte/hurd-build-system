# GNU Hurd — per-target userland derivations.  **SKELETON ONLY.**
#
# This file lands the structure (source pin, version splice, per-target
# attrs, mkReproAttrs) that mirrors flakes/gnumach + flakes/mig — but the
# actual `mkDerivation` is stubbed because nixpkgs 25.11 has zero Hurd
# kernel concept: `lib.systems.parse.kernels` only knows linux / darwin /
# freebsd / … / none / wasi / windows.  Building real Hurd userland
# requires several pre-conditions that don't exist yet:
#
#   1. Add a "hurd" (or "gnu") kernel to `lib.systems.parse.kernels` via
#      an overlay / fork — `i686-pc-gnu` currently fails to parse.
#   2. Define `i686-pc-gnu` / `x86_64-pc-gnu` cross-systems with the
#      right ABI / libc fields.
#   3. Provide a glibc-for-hurd derivation (Debian patches against
#      upstream glibc + the Hurd headers).
#   4. Build gcc cross-targeting that system (probably via overlay on
#      flakes/cross-toolchain).
#   5. Wire all of the above into a hurd-specific `mkCrossPkgs`.
#
# Until then, each `hurd-<arch>` output is marked `meta.broken = true`,
# so `nix build` refuses it with a clear message and the cache CI skips
# it.  The placeholder `runCommand` just stages a README pointer at the
# source so `nix path-info --json .#hurd-<arch>` returns something
# inspectable.
#
# Targets: only i686 / x86_64 (no -xen variant — Hurd doesn't run on
# Xen; no aarch64 — Sergey's port to ARM is on a separate branch and
# isn't on savannah master yet).  The mig sub-flake's per-arch derivations
# are passed through (they share the same toolchain pattern), so each
# hurd-<arch> already has a matching mig-<arch> in its closure once the
# real build comes online.
#
# Source comes from the pinned `hurd-src` flake input (savannah master,
# locked in flake.lock); local working clone at `src/hurd/` is a dev
# convenience populated by `make srcs`.

{ nixpkgs, system, targets, mig, gnumachHeaders, mkCrossPkgs, self, srcInput, forkUrl }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  helpers = import ../lib { inherit lib; };

  # Upstream version parsed from configure.ac (`AC_INIT([GNU Hurd], …)`).
  upstreamVersion = helpers.parseAcInitVersion (srcInput + "/configure.ac");

  # Same composeVersion the gnumach / mig derivations use — keeps the
  # PACKAGE_VERSION shape consistent across all built artefacts.
  fullVersion = helpers.composeVersion {
    inherit upstreamVersion srcInput self forkUrl;
  };

  # Hurd only targets i686 / x86_64 today.  The xen variants share the
  # same i686/x86_64 ABI but bring no separate hurd build, so we filter
  # them out here.  aarch64-hurd is parked until upstream catches up.
  hurdTargets = lib.filterAttrs
    (name: target:
      (target.crossSystem == "i686-elf" || target.crossSystem == "x86_64-elf")
      && target.platform != "xen")
    targets;

  mkOne = name: target:
    let
      pname = "hurd-${target.migTarget}";
    in
    pkgs.runCommand pname {
      version = fullVersion;
      passthru = { inherit target; };
      meta = with lib; {
        description = "GNU Hurd userland for ${target.migTarget} (SKELETON — toolchain pending)";
        platforms = platforms.all;
        broken    = true;
        longDescription = ''
          Skeleton derivation. nixpkgs has no Hurd kernel concept yet, so
          building real userland is blocked on: (1) adding a hurd kernel
          to lib.systems.parse.kernels; (2) defining i686-pc-gnu /
          x86_64-pc-gnu cross-systems; (3) packaging glibc-for-hurd; (4)
          building gcc against it.  See flakes/hurd/default.nix for the
          full TODO.
        '';
      };
    } ''
      mkdir -p $out
      cat > $out/README <<EOF
      hurd-${name} skeleton (toolchain TODO).
      Pinned src: ${srcInput}
      Version:    ${fullVersion}
      Fork:       ${forkUrl}
      See flakes/hurd/default.nix for the multi-session port plan.
      EOF
    '';
in
lib.mapAttrs' (name: target: lib.nameValuePair "hurd-${name}" (mkOne name target)) hurdTargets
