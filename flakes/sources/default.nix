# Source-repo helpers — shared by the version composer (the fork-id in
# PACKAGE_VERSION) and the Makefile `srcs` targets (clone url + the rev nix
# pins).
#
# Single source of truth is the `*-src` flake inputs in flake.nix.  nix doesn't
# expose owner/repo/ref on a fetched input value (only rev/shortRev/dates), so
# we read them back out of flake.lock — which is itself generated from those
# inputs, so nothing is redefined here.
#
# github-only for now (both sources are github forks); generalise the url
# construction if a non-github source is ever added.
{ lib }:

rec {
  # Per-source info derived from flake.lock node <inputName>:
  #   owner, repo — from the input's `original`
  #   ref         — declared branch; rev — the locked commit nix builds
  #   url         — https clone origin for `make srcs`
  #   forkUrl     — same without `.git`, fed to shortUrl for the version fork-id
  info = self: inputName:
    let
      lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
      node = lock.nodes.${inputName} or
             (throw "sources.info: flake.lock has no input '${inputName}'");
      o = node.original;
      l = node.locked;
    in {
      owner   = o.owner;
      repo    = o.repo;
      ref     = o.ref or l.ref or "HEAD";
      rev     = l.rev;
      url     = "https://github.com/${o.owner}/${o.repo}.git";
      forkUrl = "https://github.com/${o.owner}/${o.repo}";
    };

  # { <dir> = info; … } for every `*-src` flake input, keyed by their src/<dir>
  # (input "gnumach-src" → dir "gnumach").  Auto-discovered from flake.lock's
  # root node, so adding a `<name>-src` input to flake.nix makes it appear here
  # (and in `make srcs`) with no list to maintain.  Backs the `srcs` output.
  all = self:
    let
      lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
      rootInputs = lock.nodes.${lock.root}.inputs or {};
      srcNames = builtins.filter (n: lib.hasSuffix "-src" n)
        (builtins.attrNames rootInputs);
    in
    lib.listToAttrs (map
      (n: { name = lib.removeSuffix "-src" n; value = info self n; })
      srcNames);
}
