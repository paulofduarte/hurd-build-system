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
#   toolchain.nix  per-target cross-binutils + cross-gcc-stage1 + the
#                  final gcc / wrapped toolchain, merged into
#                  packages.<system> (hurd-binutils-/hurd-gcc-stage1-/
#                  hurd-gcc-/hurd-toolchain-<arch>).
#   dev-shell.nix  mkHurdDevShell — the `nix develop .#hurd-<arch>`
#                  environment for the in-tree `make hurd` build.
#   hurd-config.nix  the configure flag set shared between the nix build
#                  (flakes/hurd) and the dev shell.
#
# glibc-hurd (which consumes mig + gnumach-headers + hurd-headers) is a
# separate derivation wired in packages.nix; see glibc.nix.

{ nixpkgs, libHurd }:

let
  pkgs       = import ./pkgs.nix      { inherit nixpkgs libHurd; };
  toolchain  = import ./toolchain.nix { inherit nixpkgs; inherit (pkgs) mkHurdCrossPkgs; };
  devShell   = import ./dev-shell.nix { inherit nixpkgs; };
in

pkgs // toolchain // devShell
