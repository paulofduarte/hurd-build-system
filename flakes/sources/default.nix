# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Source-repo helpers - shared by the version composer (the fork-id) and the
# Makefile `src` targets (clone url + pinned rev).
#
# Three kinds of `*-src` root flake input:
#  - `<name>-src`            the master-tracking WORK source: cloned by `make src`,
#                            used by the shipped nix builds AND the in-tree builds,
#                            bumped by `make pin-src`.  This is the normal shape.
#  - `<name>-toolchain-src`  the frozen toolchain-bootstrap pin: feeds the glibc ->
#                            cross-gcc chain (binutils/gcc/glibc are toolchain-only
#                            and have ONLY this).  Bumped ONLY by a deliberate manual
#                            `nix flake update <name>-toolchain-src`, never `pin-src`.
#  - `<name>-dep-src`        a frozen userland-dep pin (zlib, libpciaccess - the
#                            rump-stack target libs): nix-only release tarballs,
#                            never cloned into src/, no in-tree story, and NOT part
#                            of the toolchain (bumping one rebuilds only its own
#                            consumers).  Excluded from both views below; bumped by
#                            editing the url like the toolchain trio.
#
# Nix doesn't expose owner/repo/ref on a fetched input (only rev / shortRev /
# dates), so we read them back out of flake.lock (itself generated from those
# inputs), dispatching on the `original.type` nix already parsed instead of
# writing our own URL parser.  Barrel; the bulk of `info` lives in ./info.nix.

{ lib }:

let
  # flakes/lib's url parser/shortener - used by info.nix to derive the remote
  # `name` for git-type inputs (which carry a raw url instead of owner/repo).
  flakeLib = import ../lib { inherit lib; };

  inherit (import ./info.nix { inherit lib flakeLib; }) info;

  # { <name> = info; ... } for every root `*-src` input matching `keep`, keyed by
  # the input name minus its trailing `-src` (so `gnumach-src` -> "gnumach",
  # `gnumach-toolchain-src` -> "gnumach-toolchain").  Auto-discovered from
  # flake.lock's root node, so adding an input makes it appear with no list to
  # maintain.  `inputs` is the outputs-fn attrset, used only so `info` can read
  # `.lastModifiedDate`.
  mkView =
    keep: self: inputs:
    let
      lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
      rootInputs = lock.nodes.${lock.root}.inputs or { };
      names = builtins.filter keep (builtins.attrNames rootInputs);
    in
    lib.listToAttrs (
      map (n: {
        name = lib.removeSuffix "-src" n;
        value = info self n inputs.${n};
      }) names
    );
in

{
  inherit info;

  # WORK sources (master-tracking): the plain `*-src` inputs, EXCLUDING the frozen
  # `*-toolchain-src` pins.  Backs `.#srcs` - what `make src` clones, `make pin-src`
  # bumps, and `make show-src-pins` reports; also the source the shipped nix builds
  # + the in-tree builds actually use.
  all = mkView (
    n: lib.hasSuffix "-src" n && !(lib.hasSuffix "-toolchain-src" n) && !(lib.hasSuffix "-dep-src" n)
  );

  # TOOLCHAIN pins (frozen): the `*-toolchain-src` inputs feeding the glibc ->
  # cross-gcc bootstrap.  Backs `.#toolchainSrcs`; bumped only by a deliberate
  # manual `nix flake update <name>-toolchain-src`, never by `make pin-src`.
  toolchain = mkView (n: lib.hasSuffix "-toolchain-src" n);
}
