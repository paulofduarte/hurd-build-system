# Map a host system to the cross-target whose ABI is closest to it.  Used
# by the root flake to expose `devShells.<system>.default` and by the run
# apps to pick a default arch.
#
# Target NAMES are never hard-coded here — they come from the `targets`
# attrset (target-archs.nix), so adding/removing a target is a one-file
# edit there.  We pick by matching the host CPU against each target's
# `crossTarget` CPU, preferring a "primary" target (a non-xen userland
# target).  A host with no CPU match (e.g. an aarch64 host, since
# aarch64-gnu isn't upstream yet) falls back to the widest primary.
# Override interactively with `nix develop .#<target>`.

{ nixpkgs }:

let
  inherit (nixpkgs.lib) head last filterAttrs attrNames splitString;
  cpuOf = s: head (splitString "-" s);
in

{
  # defaultTargetName : system -> targets -> name
  defaultTargetName = system: targets:
    let
      hostCpu   = cpuOf system;
      isPrimary = t: (t.platform or null) != "xen";
      primaries = filterAttrs (_: isPrimary) targets;
      cpuMatch  = filterAttrs (_: t: cpuOf t.crossTarget == hostCpu) primaries;
    in
    if cpuMatch != { } then head (attrNames cpuMatch)
    # No primary matches the host CPU: take the widest primary.  Names
    # sort lexicographically, so the 64-bit `x86_64` wins over `i686`.
    else last (attrNames primaries);
}
