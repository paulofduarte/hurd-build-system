# Source-repo helpers — shared by the version composer (the fork-id in
# PACKAGE_VERSION) and the Makefile `srcs` targets (clone url + the rev
# nix pins).
#
# Single source of truth is the `*-src` flake inputs in flake.nix.  Nix
# doesn't expose owner/repo/ref on a fetched input value (only rev /
# shortRev / dates), so we read them back out of flake.lock — which is
# itself generated from those inputs, so nothing is redefined here.
#
# Works for any supported flake input type — we dispatch on the
# `original.type` nix has already parsed into flake.lock, instead of
# writing our own URL parser.
#
# This file is a barrel; the bulk of `info` lives in ./info.nix.  `all`
# is a thin loop over the flake's `*-src` inputs and stays here.

{ lib }:

let
  # flakes/lib's existing url parser/shortener — used by info.nix only to
  # derive the remote `name` for git-type inputs (which carry a raw url
  # instead of owner/repo).  It already recognises github / gitlab /
  # codeberg / savannah hosts.
  flakeLib = import ../lib { inherit lib; };

  inherit (import ./info.nix { inherit lib flakeLib; }) info;
in

{
  inherit info;

  # { <dir> = info; … } for every `*-src` flake input, keyed by their
  # src/<dir> (input "gnumach-src" → dir "gnumach").  Auto-discovered from
  # flake.lock's root node, so adding a `<name>-src` input to flake.nix
  # makes it appear here (and in `make srcs`) with no list to maintain.
  # `inputs` is the outputs-fn `inputs` attrset (or any subset containing
  # the `*-src` values), used only so `info` can read each input's
  # `.lastModifiedDate` for the date field.  Backs the `srcs` flake output.
  all = self: inputs:
    let
      lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
      rootInputs = lock.nodes.${lock.root}.inputs or {};
      srcNames = builtins.filter (n: lib.hasSuffix "-src" n)
        (builtins.attrNames rootInputs);
    in
    lib.listToAttrs (map
      (n: { name = lib.removeSuffix "-src" n; value = info self n inputs.${n}; })
      srcNames);
}
