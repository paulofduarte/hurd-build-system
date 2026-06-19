# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Compose the full PACKAGE_VERSION string at flake eval.
#
# Shape (matching the GNU Hurd projects' `git describe --tags` outputs):
#
#   v<upstream>+git<date>-g<src>+<short-url>[+build.g<build>[-dirty]]
#
# `-` stays inside the describe-style core; the fork and build sections are each
# `+`-fenced.  Branch is omitted from the fork section - `<src>` already pins the
# commit, branches move, detached pins have none.  The `+build.g<build>` field is
# keyed on ARTIFACT ROLE: shipped artifacts (gnumach kernel, hurd userland) carry
# it; toolchain blocks omit it, so a build-system commit doesn't rehash them.
# Full rationale: README "Versioning".
#
# Three entry points:
#
#   composeFromParts - the raw string template; takes resolved parts (srcShort,
#     srcDate, forkId, optional buildShort - omitted => no `+build.g...` field).
#
#   composeVersion - pure-eval wrapper for the SHIPPED derivations.  Resolves the
#     parts from a source flake input + `self`.  Caveat: pure eval can't run git,
#     so <date> is the HEAD commit date (describe-SHAPED, not a true tag).  A
#     dirty `src/<repo>` tree is invisible (inputs lock to the committed rev);
#     only the build-system tree's dirtiness shows, as `-dirty` on `+build.`.
#
#   composeToolchainVersion - the same for TOOLCHAIN blocks: no `self`, no
#     `+build.g...` field.

{
  selfMeta,
  url,
}:

let
  inherit (selfMeta) buildRev;
  inherit (url) shortUrl;

  composeFromParts =
    {
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

  # Args: upstreamVersion (from the parsers), srcInput (-> .shortRev +
  # .lastModifiedDate), forkUrl (owner/repo from flakes/sources), self (-> buildRev),
  # buildRevToken (optional: the Makefile-fed `build-rev` input token - any
  # --override-input drops BOTH self.shortRev and self.dirtyShortRev on a clean
  # tree, baking `+build.gunknown` into override-resolved nix builds; the explicit
  # token keeps them identical to no-override/CI builds).
  composeVersion =
    {
      upstreamVersion,
      srcInput,
      forkUrl,
      self,
      buildRevToken ? null,
    }:
    composeFromParts {
      inherit upstreamVersion;
      srcShort = srcInput.shortRev or "unknown";
      srcDate = builtins.substring 0 8 (srcInput.lastModifiedDate or "00000000");
      forkId = shortUrl { url = forkUrl; };
      buildShort = if buildRevToken != null then buildRevToken else buildRev self;
    };

  # Toolchain-block variant - composeVersion with no build-rev (and no `self`).
  # The toolchain building blocks' identity is upstream version + source rev, so
  # a build-system commit must not rehash them; omitting buildShort drops the
  # `+build.g...` field.
  composeToolchainVersion =
    {
      upstreamVersion,
      srcInput,
      forkUrl,
    }:
    composeFromParts {
      inherit upstreamVersion;
      srcShort = srcInput.shortRev or "unknown";
      srcDate = builtins.substring 0 8 (srcInput.lastModifiedDate or "00000000");
      forkId = shortUrl { url = forkUrl; };
    };
}
