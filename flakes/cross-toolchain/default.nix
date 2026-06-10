# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-toolchain machinery - barrel.  THE `<cpu>-gnu` Hurd cross-toolchain
# for the repo: builds the gnumach kernel, MIG, glibc-hurd, and the Hurd
# userland - one toolchain + one dev shell.
#
# Logic lives in sibling modules:
#
#   pkgs.nix        - `mkCrossPkgs`: the only importer of the patched
#                     `<cpu>-gnu` nixpkgs (lib/systems extension from
#                     flakes/lib-systems-hurd) with `crossSystem` set, + the
#                     gas-determinism chunksize overlay.
#   toolchain.nix   - `mkAll` (cross-binutils + stage-1 cc per target), and the
#                     `mkGcc` (a complete cross-gcc vs a given target libc) /
#                     `wrappedToolchain` / `hurdTargets` helpers.  The 2-pass
#                     gcc/glibc chain is orchestrated in packages.nix.
#   gcc-runtime.nix - `mkCompiler` (the posix cross-gcc) + `mkRuntimeLib` (one split
#                     target-runtime lib built from it, without rebuilding cc1).
#   glibc.nix       - `glibc-hurd-<arch>` (imported directly by packages.nix).
#   hurd-config.nix - the configure flag set shared by the nix Hurd build
#                     (flakes/hurd) and the dev shell.
#   dev-shell.nix   - `mkDevShell`: the single per-(host, target)
#                     `nix develop` shell for the in-tree builds.
#   target.nix      - `defaultTargetName`: host CPU -> default cross-target.

{ nixpkgs, libHurd }:

let
  pkgs       = import ./pkgs.nix       { inherit nixpkgs libHurd; };
  inherit (pkgs) mkCrossPkgs;

  toolchain  = import ./toolchain.nix  { inherit nixpkgs mkCrossPkgs; };
  gccRuntime = import ./gcc-runtime.nix { inherit nixpkgs mkCrossPkgs; inherit (toolchain) wrappedToolchain; };
  devShell   = import ./dev-shell.nix  { inherit nixpkgs mkCrossPkgs; };
  target     = import ./target.nix     { inherit nixpkgs; };
in

pkgs // toolchain // gccRuntime // devShell // target
