# Hurd cross-toolchain — barrel.
#
# Distinct from flakes/cross-toolchain (bare-metal *-elf for gnumach
# kernel) — this is the *-gnu hosted toolchain for the Hurd userland.
# Imports the patched nixpkgs (lib/systems extension from
# flakes/lib-systems-hurd) to make the *-gnu triplet parse.
#
# Concern split:
#
#   pkgs.nix       mkHurdCrossPkgs — the cross nixpkgs instantiation.
#                  Only place that imports the patched source with
#                  crossSystem = "<cpu>-gnu".
#   toolchain.nix  per-target cross-binutils + cross-gcc-stage1, merged
#                  into packages.<system> as hurd-binutils-<arch> and
#                  hurd-gcc-stage1-<arch>.
#
# glibc-hurd (which consumes mig + gnumach-headers + hurd-headers) is a
# separate derivation wired in packages.nix; see glibc.nix.

{ nixpkgs, libHurd }:

let
  pkgs       = import ./pkgs.nix      { inherit nixpkgs libHurd; };
  toolchain  = import ./toolchain.nix { inherit nixpkgs; inherit (pkgs) mkHurdCrossPkgs; };
in

pkgs // toolchain
