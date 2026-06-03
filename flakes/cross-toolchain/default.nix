# Cross-toolchain machinery — barrel.  This is THE toolchain for the repo:
# the `<cpu>-gnu` Hurd cross-toolchain that builds the gnumach kernel, MIG,
# glibc-hurd, and the Hurd userland.  (Formerly split between a bare-metal
# `*-elf` cross-toolchain and a separate `hurd-toolchain`; merged here so
# there is a single toolchain + a single dev shell.)
#
# The actual logic lives in sibling modules, grouped by concern:
#
#   pkgs.nix        — `mkCrossPkgs`: the only place that imports the patched
#                     `<cpu>-gnu` nixpkgs (lib/systems extension from
#                     flakes/lib-systems-hurd) with `crossSystem` set, + the
#                     gas-determinism chunksize overlay.
#   toolchain.nix   — `mkAll` (cross-binutils + stage-1 cc per target), and the
#                     `mkGcc` (a complete cross-gcc vs a given target libc) /
#                     `wrappedToolchain` / `hurdTargets` helpers.  The 3-stage
#                     gcc/glibc chain is orchestrated in packages.nix.
#   glibc.nix       — `glibc-hurd-<arch>` (imported directly by packages.nix).
#   abi-check.nix   — `mkAbiChecked` (in-build ABI gate) + `mkAbiReport`
#                     (`make check-glibc[-full]` back-end).
#   hurd-config.nix — the configure flag set shared by the nix Hurd build
#                     (flakes/hurd) and the dev shell.
#   dev-shell.nix   — `mkDevShell`: the single per-(host, target)
#                     `nix develop` shell for the in-tree builds.
#   target.nix      — `defaultTargetName`: host CPU → default cross-target.

{ nixpkgs, libHurd }:

let
  pkgs       = import ./pkgs.nix       { inherit nixpkgs libHurd; };
  inherit (pkgs) mkCrossPkgs;

  toolchain  = import ./toolchain.nix  { inherit nixpkgs mkCrossPkgs; };
  abiCheck   = import ./abi-check.nix  { inherit nixpkgs mkCrossPkgs; };
  devShell   = import ./dev-shell.nix  { inherit nixpkgs mkCrossPkgs; };
  target     = import ./target.nix     { inherit nixpkgs; };
in

pkgs // toolchain // abiCheck // devShell // target
