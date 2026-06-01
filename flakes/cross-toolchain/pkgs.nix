# Cross nixpkgs instantiation — the only place in the flake that imports
# nixpkgs with `crossSystem` set.  Everything else (gnumach-headers, mig,
# sidekick) works with the host-side `legacyPackages.<system>` only.
#
# This imports the PATCHED nixpkgs source (the lib/systems extension from
# flakes/lib-systems-hurd, which teaches nixpkgs to parse the `<cpu>-gnu`
# Hurd triplet) with `crossSystem.config` set to the target's `<cpu>-gnu`
# config.  One cross-pkgs set serves everything: the libc-free stage-1 cc
# (gccWithoutTargetLibc) that builds gnumach-headers / mig / glibc-hurd,
# and — via toolchain.nix's wrapCCWith — the final wrapped cc that builds
# the gnumach kernel + the Hurd userland.
#
# One overlay applies on top of the patched nixpkgs:
#
#   chunksizeOverlay     Pin gas's obstack chunksize so the cross-binutils
#                        emits byte-identical `.debug_line` across hosts.
#                        Scoped to cross-targeting binutils only — leaves
#                        the native toolchain untouched.

{ nixpkgs, libHurd }:

let
  inherit (nixpkgs) lib;
in

{
  # mkCrossPkgs : system -> target -> pkgs (cross-targeting Hurd).
  # `target` is a target-archs.nix entry; its `.crossTarget` field is the
  # `<cpu>-gnu` config string the cross-system is built for.
  mkCrossPkgs = system: target:
    let
      patchedSrc = libHurd.patchedNixpkgsSrc { inherit system; };

      # gas left at chunksize=0 takes the obstack library's *default* chunk
      # size, which differs between glibc's and libiberty's obstack.  That
      # shifts frag_grow's chunk-exhaustion split points, flipping the
      # `.debug_line` encoding (DW_LNE_set_address vs a relative advance) for
      # identical input — so the same source assembled to byte-different `.o`
      # across build hosts.  This patch pins chunksize (still `int chunksize
      # = 0;` upstream as of binutils 2.46 — not fixed there; the patch is a
      # one-line context-stable change that applies clean across 2.44–2.46).
      #
      # Scoped via `hostPlatform.config != targetPlatform.config` so it
      # patches only the cross-targeting binutils.  That also rebuilds the
      # cross-gcc against the patched `as`, making its bundled libgcc (linked
      # into every kernel) deterministic too — while leaving the native
      # toolchain untouched (a global overlay would cascade a native rebuild
      # on Linux).
      chunksizeOverlay = final: prev:
        lib.optionalAttrs
          (prev.stdenv.hostPlatform.config != prev.stdenv.targetPlatform.config)
          {
            binutils-unwrapped = prev.binutils-unwrapped.overrideAttrs (old: {
              patches = (old.patches or [])
                ++ [ ./patches/binutils-gas-deterministic-chunksize.patch ];
            });
          };
    in
    import patchedSrc {
      localSystem.system = system;
      crossSystem.config = target.crossTarget;
      overlays = [ chunksizeOverlay ];
    };
}
