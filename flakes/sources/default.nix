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

  # `*-src` inputs that are NOT in-tree source projects: pinned in
  # flake.nix for reproducibility, never cloned into src/ by `make srcs`,
  # and never `--override-input`-ed by `make`.  Today just the `*-ref-src`
  # reference twins (frozen release tags that the reference glibc — and hence
  # gcc's libgcc_s/libstdc++ — bind; see TOOLCHAIN-LIBC-DECOUPLING.md).  They
  # must stay un-overridable: --override-input is eval-global, so an in-tree
  # clone of one would drag the reference glibc, and thus gcc, into every
  # rebuild.  Bump them together via `make rebaseline-ref`.  (The old
  # `*-bootstrap-src` seeds were retired with the 2-pass bootstrap — the nolibc
  # stage-1 cc now builds the reference glibc directly; no throwaway seed.)
  # glibc-src itself is NOT here — the working glibc is hackable in-tree
  # like gnumach/mig/hurd (`make srcs` clones it; `make` overrides it).
  toolchainOnly = [
    "gnumach-ref-src" "mig-ref-src" "hurd-ref-src" "glibc-ref-src"
  ];
in

{
  inherit info;

  # { <dir> = info; … } for every in-tree `*-src` flake input, keyed by
  # their src/<dir> (input "gnumach-src" → dir "gnumach").  Auto-discovered
  # from flake.lock's root node, minus `toolchainOnly`, so adding an
  # in-tree `<name>-src` input to flake.nix makes it appear here (and in
  # `make srcs`) with no list to maintain.  `inputs` is the outputs-fn
  # `inputs` attrset (or any subset containing the `*-src` values), used
  # only so `info` can read each input's `.lastModifiedDate`.  Backs the
  # `srcs` flake output.
  all = self: inputs:
    let
      lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
      rootInputs = lock.nodes.${lock.root}.inputs or {};
      srcNames = builtins.filter
        (n: lib.hasSuffix "-src" n && !(builtins.elem n toolchainOnly))
        (builtins.attrNames rootInputs);
    in
    lib.listToAttrs (map
      (n: { name = lib.removeSuffix "-src" n; value = info self n inputs.${n}; })
      srcNames);
}
