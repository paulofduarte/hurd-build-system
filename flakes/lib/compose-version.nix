# Compose the full PACKAGE_VERSION string at flake eval — no shell needed.
#
# Shape (matching the GNU Hurd projects' `git describe --tags` outputs):
#
#   v<upstream>+git<date>-g<src>+<short-url>+build.g<build>[-dirty]
#
# `-` stays inside the describe-style core; the fork and build sections
# are each `+`-fenced.  Branch is intentionally omitted from the fork
# section — `<src>` already uniquely identifies the commit, branches
# move (or get deleted), and detached pins have no branch.  Full format
# rationale (and why it is intentionally not semver) lives in the README
# "Versioning" section.
#
# Two entry points:
#
#   composeFromParts — the raw string template; takes already-resolved
#     parts (srcShort, srcDate, forkId, buildShort).  The local-source
#     splice path (flakes/sources/local-version.sh, via
#     `.#srcs.<name>.localVersion`) feeds into this too, so the format
#     stays in lockstep across nix-built and local in-tree paths.
#
#   composeVersion — pure-eval wrapper for the nix-built derivations.
#     Resolves the parts itself from a source flake input + the flake's
#     `self`.  Caveat: pure eval can't run git, so <date> is the HEAD
#     commit date (not a real tag) and there is no commit-count —
#     describe-SHAPED, not a true tag.  A dirty `src/<repo>` tree is
#     invisible (inputs lock to the committed rev); only the build-system
#     tree's dirtiness shows, as `-dirty` on the `+build.` field.

{ lib, selfMeta, url }:

let
  inherit (selfMeta) buildRev;
  inherit (url) shortUrl;

  composeFromParts = {
    upstreamVersion,
    srcShort,
    srcDate,
    forkId,
    buildShort,
  }:
    "v${upstreamVersion}+git${srcDate}-g${srcShort}+${forkId}+build.g${buildShort}";
in

{
  inherit composeFromParts;

  # Args (eval-time): upstreamVersion (from parseM4Version /
  # parseAcInitVersion), srcInput (source flake input → .shortRev +
  # .lastModifiedDate), forkUrl (owner/repo from flakes/sources), self
  # (the build flake — feeds buildRev).
  composeVersion = {
    upstreamVersion,
    srcInput,
    forkUrl,
    self,
  }:
    composeFromParts {
      inherit upstreamVersion;
      srcShort   = srcInput.shortRev or "unknown";
      srcDate    = builtins.substring 0 8 (srcInput.lastModifiedDate or "00000000");
      forkId     = shortUrl { url = forkUrl; };
      buildShort = buildRev self;
    };
}
