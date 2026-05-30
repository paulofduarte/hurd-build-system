# Source-repo helpers — shared by the version composer (the fork-id in
# PACKAGE_VERSION) and the Makefile `srcs` targets (clone url + the rev nix
# pins).
#
# Single source of truth is the `*-src` flake inputs in flake.nix.  nix doesn't
# expose owner/repo/ref on a fetched input value (only rev/shortRev/dates), so
# we read them back out of flake.lock — which is itself generated from those
# inputs, so nothing is redefined here.
#
# Works for any supported flake input type — we dispatch on the `original.type`
# nix has already parsed into flake.lock, instead of writing our own URL parser.
{ lib }:

let
  # flakes/lib's existing url parser/shortener — used here only to derive the
  # remote `name` for git-type inputs (which carry a raw url instead of
  # owner/repo).  It already recognises github/gitlab/codeberg/savannah hosts.
  flakeLib = import ../lib { inherit lib; };
in

rec {
  # Per-source info derived from flake.lock node <inputName> + the resolved
  # input value:
  #   ref     — declared branch; rev — the locked commit nix builds
  #   date    — locked commit date (YYYY-MM-DD) from input.lastModifiedDate
  #   url     — clone url for `make srcs`
  #   forkUrl — fed to shortUrl for the version fork-id
  #   name    — stable host-named remote (e.g. github.<owner>.<repo>,
  #             savannah.<project>.<repo>) — what `make srcs` calls the
  #             pin's remote, consistent across environments and matching
  #             the PACKAGE_VERSION fork field (minus the branch).
  info = self: inputName: input:
    let
      lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
      node = lock.nodes.${inputName} or
             (throw "sources.info: flake.lock has no input '${inputName}'");
      o = node.original;
      l = node.locked;
      d = input.lastModifiedDate or "00000000";

      # Per-type clone url + fork url + remote name.  No URL parsing of our
      # own — we just consume the fields nix has already parsed into
      # `original`; only the git type defers to flakes/lib's shortUrl to
      # turn a raw url into a dotted host.owner.repo.
      byType =
        if o.type == "github" then {
          url     = "https://github.com/${o.owner}/${o.repo}.git";
          forkUrl = "https://github.com/${o.owner}/${o.repo}";
          name    = "github.${o.owner}.${o.repo}";
        }
        else if o.type == "gitlab" then {
          url     = "https://gitlab.com/${o.owner}/${o.repo}.git";
          forkUrl = "https://gitlab.com/${o.owner}/${o.repo}";
          name    = "gitlab.${o.owner}.${o.repo}";
        }
        else if o.type == "sourcehut" then {
          url     = "https://git.sr.ht/~${o.owner}/${o.repo}";
          forkUrl = "https://git.sr.ht/~${o.owner}/${o.repo}";
          name    = "sourcehut.${o.owner}.${o.repo}";
        }
        else if o.type == "git" then {
          url     = o.url;
          forkUrl = lib.removeSuffix ".git" o.url;
          name    = flakeLib.shortUrl {
            url = lib.removeSuffix ".git" o.url;
          };
        }
        else
          throw "sources.info: input '${inputName}' has unsupported type '${o.type}'";
    in {
      inherit (byType) url forkUrl name;
      ref  = o.ref or l.ref or "HEAD";
      rev  = l.rev;
      date = "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";

      # Compose the local-source PACKAGE_VERSION given the working clone's
      # current git state — feeds flakes/sources/local-version.sh's splice.
      # Same template as the nix-built version (flakes/lib's composeFromParts),
      # same fork-id (byType.name); the only extras are the `-dirty` markers
      # which pure-eval composeVersion can't see.
      localVersion = {
        upstreamVersion,
        srcShort,
        srcDate,
        srcDirty   ? false,
        buildShort,
        buildDirty ? false,
      }:
        flakeLib.composeFromParts {
          inherit upstreamVersion srcDate;
          srcShort   = srcShort   + (if srcDirty   then "-dirty" else "");
          buildShort = buildShort + (if buildDirty then "-dirty" else "");
          forkId     = byType.name;
        };
    };

  # { <dir> = info; … } for every `*-src` flake input, keyed by their src/<dir>
  # (input "gnumach-src" → dir "gnumach").  Auto-discovered from flake.lock's
  # root node, so adding a `<name>-src` input to flake.nix makes it appear here
  # (and in `make srcs`) with no list to maintain.  `inputs` is the outputs-fn
  # `inputs` attrset (or any subset containing the `*-src` values), used only
  # so `info` can read each input's `.lastModifiedDate` for the date field.
  # Backs the `srcs` output.
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
