# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Reproducibility attrs for `mkDerivation` - merge in with `//`.  The
# host-independence knobs not tied to the source layout (the caller still owns
# `preConfigure`, the autoconf-flavor-specific version splice).

{ lib }:

{
  mkReproAttrs = { pname, version }: {
    # -frandom-seed comes from nixpkgs' reproducible-builds.sh hook, as the first
    # 10 chars of ${NIX_OUTPATH_USED_AS_RANDOM_SEED:-$out}.  Override the $out
    # default: $out is host-specific for a cross derivation, which would make the
    # seed host-specific and break cross-host reproducibility.  Hashing
    # `${pname}-${version}` keeps the seed host-independent yet distinct per
    # target+build.  nix32 (no symbols) avoids a `/` clashing with the hook's
    # `${randSeed##*/}` trim.
    NIX_OUTPATH_USED_AS_RANDOM_SEED =
      "/" + builtins.convertHash {
        hash = builtins.hashString "sha256" "${pname}-${version}";
        hashAlgo = "sha256";
        toHashFormat = "nix32";
      };

    # Normalise the build-dir path embedded in DWARF: Linux nix uses /build,
    # Darwin /nix/var/nix/builds/...; rewrite both to /build so DWARF
    # .debug_str / .debug_line_str are byte-identical across hosts.
    preBuild = ''
      export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -fdebug-prefix-map=$NIX_BUILD_TOP=/build"
    '';
  };

  # Content-addressed output (`ca-derivations` experimental feature): the
  # store path derives from the OUTPUT hash, so downstream derivations resolve
  # against what the package IS, not how it was built.  A source change that
  # leaves the installed tree byte-identical (e.g. a .c-only edit upstream of
  # a headers-only package) stops the rebuild cascade here (early cutoff).
  # Precondition: the output must be byte-reproducible.
  mkCaAttrs = enable: lib.optionalAttrs enable {
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  };
}
