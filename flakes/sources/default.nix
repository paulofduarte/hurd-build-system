# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Source-repo helpers - shared by the version composer (the fork-id) and the
# Makefile `src` targets (clone url + pinned rev).
#
# Single source of truth is the `*-src` flake inputs.  Nix doesn't expose
# owner/repo/ref on a fetched input (only rev / shortRev / dates), so we read
# them back out of flake.lock (itself generated from those inputs), dispatching
# on the `original.type` nix already parsed instead of writing our own URL parser.
#
# Barrel; the bulk of `info` lives in ./info.nix.  `all` is a thin loop over the
# `*-src` inputs and stays here.

{ lib }:

let
  # flakes/lib's url parser/shortener - used by info.nix to derive the remote
  # `name` for git-type inputs (which carry a raw url instead of owner/repo).
  flakeLib = import ../lib { inherit lib; };

  inherit (import ./info.nix { inherit lib flakeLib; }) info;

  # `*-src` inputs that are NOT in-tree source projects: never cloned into src/
  # by `make src`.  glibc is nix-only (the gcc model) - version picking = edit
  # the input in flake.nix; patches live in flakes/cross-toolchain/glibc.nix.
  # The pins themselves stay clone sources (src/<m> baselines = the pinned
  # tags); in-tree overrides rebind the *-dev-src ALIASES, which are filtered
  # out below (follows refs - no lock node of their own).
  toolchainOnly = [
    "glibc-src"
  ];
in

{
  inherit info;

  # { <dir> = info; ... } for every in-tree `*-src` input, keyed by src/<dir>
  # (input "gnumach-src" -> dir "gnumach").  Auto-discovered from flake.lock's
  # root node minus `toolchainOnly`, so adding an in-tree `<name>-src` input
  # makes it appear here (and in `make src`) with no list to maintain.  `inputs`
  # is the outputs-fn attrset, used only so `info` can read `.lastModifiedDate`.
  # Backs the `srcs` flake output.
  all = self: inputs:
    let
      lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
      rootInputs = lock.nodes.${lock.root}.inputs or {};
      srcNames = builtins.filter
        (n: lib.hasSuffix "-src" n && !(lib.hasSuffix "-dev-src" n)
            && !(builtins.elem n toolchainOnly))
        (builtins.attrNames rootInputs);
    in
    lib.listToAttrs (map
      (n: { name = lib.removeSuffix "-src" n; value = info self n inputs.${n}; })
      srcNames);
}
