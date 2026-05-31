# Per-source information derived from a `*-src` flake input + its
# matching flake.lock node.  Returns an attrset of:
#
#   ref          — declared branch (from flake.nix); falls back to the
#                  locked ref if the input didn't pin one explicitly.
#   rev          — the locked commit nix actually builds.
#   date         — locked commit date (YYYY-MM-DD) from
#                  input.lastModifiedDate.
#   url          — clone url for `make srcs` to feed `git clone`.
#   forkUrl      — fork URL fed into shortUrl for the version fork-id
#                  (no .git suffix).
#   name         — stable host-named remote (e.g. `github.<owner>.<repo>`,
#                  `savannah.<project>.<repo>`).  What `make srcs` calls
#                  the pin's remote, consistent across environments and
#                  matching the PACKAGE_VERSION fork field.
#
# No URL parsing of our own — we just consume the fields nix has already
# parsed into `original`; only the git type defers to flakes/lib's
# shortUrl to turn a raw url into a dotted host.owner.repo.

{ lib, flakeLib }:

{
  info = self: inputName: input:
    let
      lock = builtins.fromJSON (builtins.readFile (self.outPath + "/flake.lock"));
      node = lock.nodes.${inputName} or
             (throw "sources.info: flake.lock has no input '${inputName}'");
      o = node.original;
      l = node.locked;
      d = input.lastModifiedDate or "00000000";

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
    };
}
