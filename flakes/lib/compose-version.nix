# Compose the full PACKAGE_VERSION string at flake eval — no shell needed.
#
# Shape (matching the GNU Hurd projects' `git describe --tags` outputs):
#
#   v<upstream>+git<date>-g<src>+<short-url>[+build.g<build>[-dirty]]
#
# `-` stays inside the describe-style core; the fork and build sections
# are each `+`-fenced.  Branch is intentionally omitted from the fork
# section — `<src>` already uniquely identifies the commit, branches
# move (or get deleted), and detached pins have no branch.  The
# `+build.g<build>` field is keyed on ARTIFACT ROLE: shipped artifacts
# (gnumach kernel, hurd userland) carry it; toolchain blocks
# (gnumach-headers, hurd-headers, mig, glibc-hurd) omit it (their
# identity is upstream version + source rev, so a build-system commit
# must not rehash them).  Full format rationale lives in the README
# "Versioning" section.
#
# Three entry points:
#
#   composeFromParts — the raw string template; takes already-resolved
#     parts (srcShort, srcDate, forkId, and an optional buildShort —
#     omitted ⇒ no `+build.g…` field).  The local-source splice path
#     (flakes/sources/local-version.sh, via `.#srcs.<name>.localVersion`)
#     feeds into this too, so the format stays in lockstep across
#     nix-built and local in-tree paths.
#
#   composeVersion — pure-eval wrapper for the SHIPPED derivations.
#     Resolves the parts itself from a source flake input + the flake's
#     `self` (→ build-rev).  Caveat: pure eval can't run git, so <date>
#     is the HEAD commit date (not a real tag) and there is no
#     commit-count — describe-SHAPED, not a true tag.  A dirty `src/<repo>`
#     tree is invisible (inputs lock to the committed rev); only the
#     build-system tree's dirtiness shows, as `-dirty` on the `+build.`
#     field.
#
#   composeToolchainVersion — the same, for TOOLCHAIN blocks: no `self`,
#     no `+build.g…` field, so build-system commits don't rehash them.

{ lib, selfMeta, url }:

let
  inherit (selfMeta) buildRev;
  inherit (url) shortUrl;

  composeFromParts = {
    upstreamVersion,
    srcShort,
    srcDate,
    forkId,
    buildShort ? null,
  }:
    "v${upstreamVersion}+git${srcDate}-g${srcShort}+${forkId}"
    + (if buildShort == null then "" else "+build.g${buildShort}");
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

  # Toolchain-block variant — same as composeVersion but with no build-rev
  # (and so no `self`).  build-rev is provenance for the shipped artifacts
  # (gnumach kernel, hurd userland); the toolchain building blocks
  # (gnumach-headers, hurd-headers, mig, glibc-hurd) are tools whose
  # identity is upstream version + source rev, so a build-system commit
  # must not rehash them.  Omitting buildShort drops the `+build.g…` field.
  composeToolchainVersion = {
    upstreamVersion,
    srcInput,
    forkUrl,
  }:
    composeFromParts {
      inherit upstreamVersion;
      srcShort = srcInput.shortRev or "unknown";
      srcDate  = builtins.substring 0 8 (srcInput.lastModifiedDate or "00000000");
      forkId   = shortUrl { url = forkUrl; };
    };
}
