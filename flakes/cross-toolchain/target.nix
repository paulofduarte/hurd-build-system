# Map a host system to the cross-target whose ABI is closest to it.  Used
# by the root flake to expose `devShells.<system>.default` and by the run
# apps to pick a default arch.  Hosts without a matching cross-target
# (armv6l / armv7l / riscv64 / powerpc64le) fall through to aarch64 —
# the most generic 64-bit default.  Override interactively with
# `nix develop .#<target>` for anything else.

{ nixpkgs }:

let
  inherit (nixpkgs) lib;
in

{
  defaultTargetName = system:
    if lib.hasPrefix "aarch64-" system then "aarch64"
    else if lib.hasPrefix "x86_64-" system then "x86_64"
    else if lib.hasPrefix "i686-" system then "i686"
    else "aarch64";
}
