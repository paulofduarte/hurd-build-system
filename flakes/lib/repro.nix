# Reproducibility attrs for `mkDerivation` — merge into the derivation
# with `//`.  The caller still owns `preConfigure` (because the version
# splice pattern is autoconf-flavor-specific); these are the
# host-independence knobs that aren't tied to the source layout.

{ lib }:

{
  mkReproAttrs = { pname, version }: {
    # -frandom-seed comes from nixpkgs' reproducible-builds.sh hook, as
    # the first 10 chars of ${NIX_OUTPATH_USED_AS_RANDOM_SEED:-$out}.
    # Override the $out default: for a cross derivation $out is host-
    # specific, which would make the seed host-specific and break cross-
    # host reproducibility.  Hashing `${pname}-${version}` keeps the
    # 10-char-trimmed seed host-independent yet distinct per target+build
    # (a readable prefix would be truncated to just the pname).  nix32
    # (nix's store-hash alphabet, no symbols) avoids a `/` clashing with
    # the hook's `${randSeed##*/}` trim.
    NIX_OUTPATH_USED_AS_RANDOM_SEED =
      "/" + builtins.convertHash {
        hash = builtins.hashString "sha256" "${pname}-${version}";
        hashAlgo = "sha256";
        toHashFormat = "nix32";
      };

    # Normalise the build-dir path embedded in DWARF.  Linux nix uses
    # /build; Darwin uses /nix/var/nix/builds/nix-<pid>-<rand>/.  Both
    # get rewritten to /build so DWARF .debug_str / .debug_line_str are
    # byte-identical across hosts.
    preBuild = ''
      export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -fdebug-prefix-map=$NIX_BUILD_TOP=/build"
    '';
  };
}
