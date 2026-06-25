# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-toolchain machinery - barrel.  THE `<cpu>-gnu` Hurd cross-toolchain
# for the repo: builds the gnumach kernel, MIG, glibc-hurd, and the Hurd
# userland - one toolchain + one dev shell.
#
# The toolchain proper is built FROM SOURCE, unwrapped, in sibling modules that
# packages.nix imports directly (not through this barrel):
#
#   binutils.nix    - `cross-binutils-<arch>` (from the pinned tarball).
#   gcc.nix         - `bootstrap-gcc-<arch>` + the merged full `cross-gcc-<arch>`
#                     (compiler + target runtime), unwrapped, against ownBinutils.
#   glibc.nix       - `glibc-hurd-<arch>` (cross-gcc's libcCross + shipped libc).
#   hurd-stubs.nix  - the extracted floating Mach/Hurd RPC stub libs.
#
# This barrel exposes only the host-facing bits keyed off (host, target):
#
#   hurd-config.nix - the configure flag set shared by the nix Hurd build
#                     (flakes/hurd) and the dev shell.
#   dev-shell.nix   - `mkDevShell`: the single per-(host, target)
#                     `nix develop` shell for the in-tree builds.
#   target.nix      - `defaultTargetName`: host CPU -> default cross-target.

{
  nixpkgs, # branch (dev-shell runtime/dev tools)
  nixpkgs-toolchain, # frozen (dev-shell build tools, matching the cached modules)
}:

let
  devShell = import ./dev-shell.nix { inherit nixpkgs nixpkgs-toolchain; };
  target = import ./target.nix { inherit nixpkgs; };
in

devShell // target
