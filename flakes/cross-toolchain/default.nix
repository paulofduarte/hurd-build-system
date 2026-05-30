# Cross-toolchain machinery.  This file is a barrel — the actual logic
# lives in sibling modules, grouped by concern:
#
#   pkgs.nix        — `mkCrossPkgs`: the only place that imports nixpkgs
#                     with `crossSystem` set (+ the binutils chunksize
#                     patch overlay and the x86_64-darwin config.sub
#                     overlay).
#   toolchain.nix   — `mkToolchain` (the wrapped cross cc as a buildable
#                     derivation) and `mkReproDebugFlags` (the DWARF
#                     `-fdebug-prefix-map` flags that rewrite the
#                     toolchain's nix-store paths to stable `/cross-*`
#                     names).
#   dev-shell.nix   — `mkDevShell`: per-(host, target) `nix develop`
#                     shell with cross CC/LD/AR/… env vars + the
#                     in-tree-build helpers.
#   target.nix      — `defaultTargetName`: host CPU → closest cross-
#                     target name (for `devShells.<system>.default`).

{ nixpkgs }:

let
  pkgs        = import ./pkgs.nix       { inherit nixpkgs; };
  inherit (pkgs) mkCrossPkgs;

  toolchain   = import ./toolchain.nix  { inherit nixpkgs mkCrossPkgs; };
  devShell    = import ./dev-shell.nix  { inherit nixpkgs mkCrossPkgs; };
  target      = import ./target.nix     { inherit nixpkgs; };
in

pkgs // toolchain // devShell // target
