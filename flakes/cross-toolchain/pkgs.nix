# Cross nixpkgs instantiation — the only place in the flake that imports
# nixpkgs with `crossSystem` set.  Everything else (gnumach-headers, mig,
# sidekick) works with the host-side `legacyPackages.<system>` only.
#
# Two overlays apply on top of stock nixpkgs:
#
#   chunksizeOverlay     Pin gas's obstack chunksize so the cross-binutils
#                        emits byte-identical `.debug_line` across hosts.
#                        Scoped to cross-targeting binutils only — leaves
#                        the native toolchain untouched.
#
#   gnuConfigOverlay     Force-add updateAutotoolsGnuConfigScriptsHook to
#                        the bootstrap GCCs + newlib on x86_64-darwin
#                        (whose stdenv ships without it).  Without the
#                        hook, the affected derivations keep their bundled
#                        2021-vintage config.sub, which rejects
#                        `*-unknown-none-elf`.

{ nixpkgs }:

let
  inherit (nixpkgs) lib;
in

{
  mkCrossPkgs = system: target:
    let
      # Probe nixpkgs once with no overlays + no crossSystem to discover
      # the current default gcc attribute name ("gcc14" today, "gcc15"
      # tomorrow).  The gnuConfigOverlay below overrides that attribute
      # by name; reading it dynamically keeps a nixpkgs bump from
      # silently breaking this flake.
      probePkgs = import nixpkgs { localSystem = { inherit system; }; };
      gccAttr   = "gcc${lib.versions.major probePkgs.gcc.version}";

      # x86_64-darwin's stdenv is the only one missing
      # `updateAutotoolsGnuConfigScriptsHook` (26.05 is the last nixpkgs
      # release to support x86_64-darwin, so it won't be fixed upstream).
      # Without the hook, the affected derivations keep their bundled
      # 2021-vintage config.sub, which rejects `*-unknown-none-elf` with
      # "Kernel `none' not known to work with OS `elf'" (fixed only in
      # nixpkgs' replacement config.sub).  Add the hook to the three
      # bootstrap derivations that need it: the final cross-GCC
      # (${gccAttr}), the stage-1 gccWithoutTargetLibc, and newlib.  The
      # GCCs are wrapped — re-route via `.override { cc = …; }` so the
      # wrap-time args survive; newlib is plain, so `.overrideAttrs`.
      gnuConfigOverlay = final: prev:
        let
          hook = prev.buildPackages.updateAutotoolsGnuConfigScriptsHook;
          addHookAttrs = drv: drv.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ hook ];
          });
          addHookToCc = wrapped: wrapped.override {
            cc = addHookAttrs wrapped.cc;
          };
        in {
          "${gccAttr}"         = addHookToCc prev.${gccAttr};
          gccWithoutTargetLibc = addHookToCc prev.gccWithoutTargetLibc;
          newlib               = addHookAttrs prev.newlib;
        };

      # gas left at chunksize=0 takes the obstack library's *default* chunk
      # size, which differs between glibc's and libiberty's obstack.  That
      # shifts frag_grow's chunk-exhaustion split points, flipping the
      # `.debug_line` encoding (DW_LNE_set_address vs a relative advance) for
      # identical input — so the same source assembled to byte-different `.o`
      # across build hosts.  This patch pins chunksize.
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
                ++ [ ./patches/binutils-2.44-gas-deterministic-chunksize.patch ];
            });
          };
    in
    import nixpkgs {
      localSystem = { inherit system; };
      crossSystem = target.crossSystem;
      overlays = [ chunksizeOverlay ]
        ++ lib.optional (system == "x86_64-darwin") gnuConfigOverlay;
    };
}
