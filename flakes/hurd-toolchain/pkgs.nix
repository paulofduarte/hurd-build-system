# Hurd cross nixpkgs instantiation — the only place in the flake that
# imports the PATCHED nixpkgs source (with the lib/systems extension
# from flakes/lib-systems-hurd applied) with `crossSystem` set to a
# `<cpu>-gnu` triplet.
#
# Distinct from flakes/cross-toolchain/pkgs.nix (which imports STOCK
# nixpkgs with `crossSystem = "i686-elf"` for the freestanding gnumach
# kernel build).  The two paths are kept separate so kernel iteration
# (gnumach, mig, gnumach-headers, sidekick) is never blocked on a
# working glibc-hurd cross-stdenv, the kernel toolchain's cross-host
# determinism story stays intact, and the Hurd userland toolchain can
# be rebuilt without forcing a kernel rebuild.  The cost is two nixpkgs
# instantiations per host system, both cached after first use.
#
# Triplet: target.hurdCrossSystem — the canonical 2-tuple `<cpu>-gnu`
# (Debian / cross-hurd / upstream gnumach convention).  The lib.systems
# patch normalises *-pc-gnu and *-unknown-gnu inputs to this form, so
# target-archs.nix may use whichever spelling.

{ nixpkgs, libHurd }:

{
  # mkHurdCrossPkgs : system -> target -> pkgs (cross-targeting Hurd).
  # `target` is a target-archs.nix entry; its `.hurdCrossSystem` field
  # drives the cross-system selection.
  mkHurdCrossPkgs = system: target:
    let
      patchedSrc = libHurd.patchedNixpkgsSrc { inherit system; };
    in
    import patchedSrc {
      localSystem.system = system;
      crossSystem.config = target.hurdCrossSystem;
      # No overlays needed: binutils + gccWithoutTargetLibc have no libc
      # dependency, and glibc-hurd is built as a standalone derivation
      # (see glibc.nix) rather than by overriding pkgs.glibc here.
      overlays = [ ];
    };
}
