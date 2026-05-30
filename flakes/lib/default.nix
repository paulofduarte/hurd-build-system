# Shared helpers used by every per-target derivation (gnumach, mig, and
# any future ones — hurd, glibc, …).
#
# Two responsibilities:
#
#   1. Compose a rich, byte-deterministic PACKAGE_VERSION shaped after the
#      Hurd `git describe` strings (see composeVersion + README), plus a
#      pinned `-frandom-seed` and a normalised build dir in DWARF.
#
#   2. Keep the per-derivation .nix files small.  Sub-flakes import these
#      helpers, compose the version string at flake-eval time, and splice
#      it into autoconf from their own preConfigure.
#
# Data sources for the version components (all read at flake eval, all
# pure — no impure flag needed, no in-sandbox git):
#
#   upstream version  — parsed from version.m4 / configure.ac via
#                       builtins.readFile (`parseM4Version`,
#                       `parseAcInitVersion`)
#   <date>            — `<srcInput>.lastModifiedDate` (YYYYMMDD subset)
#   <fork-id>         — owner/repo of the source fork, passed in from
#                       ./sources.nix (`shortUrl`)
#   <src-hash>        — `<srcInput>.shortRev`
#   <build-hash>      — `self.shortRev or self.dirtyShortRev`
#
# `<srcInput>` is the pinned source flake input (`github:<owner>/<repo>/<ref>`,
# see flake.nix).  Its `.shortRev` / `.lastModifiedDate` are read at pure eval;
# src-hash always reflects the locked (committed + pushed) rev.

{ lib }:

rec {
  # ==========================================================================
  # Eval-time helpers — parse upstream version strings
  # ==========================================================================

  # Parse `m4_define([AC_PACKAGE_VERSION], [X])` from a version.m4 file
  # (gnumach-style autoconf input).  Returns "unknown" if no match.
  #
  # NB: nix's builtins.match uses POSIX ERE, which rejects `\(`/`\[` as
  # invalid escapes.  Literals are spelled via single-char classes:
  # `[(]` matches `(`, `[[]` matches `[`, `[]]` matches `]`.  `.`
  # already matches newlines in nix's regex, so no multi-line dance.
  parseM4Version = path:
    let
      content = builtins.readFile path;
      match = builtins.match
        ".*m4_define[(][[]AC_PACKAGE_VERSION[]],[[]([0-9.]+)[]][)].*" content;
    in
    if match == null then "unknown" else builtins.head match;

  # Parse the version arg of `AC_INIT([Name], [X], …)` from configure.ac
  # (mig-style autoconf input).  Returns "unknown" if no match.
  parseAcInitVersion = path:
    let
      content = builtins.readFile path;
      match = builtins.match
        ".*AC_INIT[(][[][^]]*[]], [[]([0-9.]+)[]], .*" content;
    in
    if match == null then "unknown" else builtins.head match;

  # ==========================================================================
  # Eval-time helpers — derive metadata from flake `self`
  # ==========================================================================

  # Build-system rev — `<short>` when clean, `<short>-dirty` when dirty.
  # Nix already appends `-dirty` itself, so this is just an `or` chain.
  buildRev = self:
    self.shortRev or self.dirtyShortRev or "unknown";

  # Build-system date as YYYYMMDD.  Available even on dirty trees.
  buildDate = self:
    builtins.substring 0 8 (self.lastModifiedDate or "00000000");

  # ==========================================================================
  # URL → dotted-identifier short form
  # ==========================================================================
  #
  # Parses common git hosting URLs into a dotted identifier string for the
  # fork/remote section of the version (see composeVersion):
  #
  #   github URLs → "github.<owner>.<repo>"
  #   gitlab URLs → "gitlab.<owner>.<repo>"
  #   codeberg    → "codeberg.<owner>.<repo>"
  #   savannah    → "savannah.<project>.<repo>"
  #   any other   → "unknown"  (hostnames never leak)
  #
  # Each `.`-separated piece is one semver build-metadata identifier
  # (`[0-9A-Za-z-]`).

  _parseUrl = url:
    let
      cleanUrl = lib.removeSuffix ".git" url;
      patterns = [
        { type = "github";   re = "https?://github[.]com/([^/]+)/([^/]+)"; }
        { type = "gitlab";   re = "https?://gitlab[.]com/([^/]+)/([^/]+)"; }
        { type = "codeberg"; re = "https?://codeberg[.]org/([^/]+)/([^/]+)"; }
        { type = "savannah"; re = "https?://git[.]savannah[.]gnu[.]org/git/([^/]+)/([^/]+)"; }
      ];
      tryOne = acc: p:
        if acc != null then acc
        else
          let m = builtins.match p.re cleanUrl; in
          if m == null then null
          else { type = p.type; owner = builtins.elemAt m 0; repo = builtins.elemAt m 1; };
    in
    builtins.foldl' tryOne null patterns;

  # Build a dotted short identifier from a URL.
  shortUrl = { url }:
    let parsed = _parseUrl url; in
    if parsed == null
    then "unknown"
    else "${parsed.type}.${parsed.owner}.${parsed.repo}";

  # ==========================================================================
  # Compose the full version string at flake eval (no shell needed)
  # ==========================================================================

  # PACKAGE_VERSION shaped after the GNU Hurd `git describe --tags` strings
  # (e.g. gnumach v1.8+git20260224-59-g79f3013):
  #
  #   v<upstream>+git<date>-g<src>+<short-url>+build.g<build>[-dirty]
  #
  # `-` stays inside the describe-style core; the fork and build sections are
  # each `+`-fenced.  Branch is intentionally omitted from the fork section —
  # `<src>` already uniquely identifies the commit, branches move (or get
  # deleted), and detached pins have no branch.  Full format rationale (and
  # why it is intentionally not semver) lives in the README "Versioning"
  # section.
  #
  # The actual string template lives in `composeFromParts` below so the
  # local-source splice (flakes/sources/local-version.sh, via
  # `.#srcs.<name>.localVersion`) shares it byte-for-byte.

  # The raw template — both pure-eval (composeVersion, below) and impure
  # local-git introspection feed into this.  Touching the format means
  # touching this one place.
  composeFromParts = {
    upstreamVersion,
    srcShort,
    srcDate,
    forkId,
    buildShort,
  }:
    "v${upstreamVersion}+git${srcDate}-g${srcShort}+${forkId}+build.g${buildShort}";

  # Pure-eval wrapper for the nix-built derivations.
  #
  # Caveat: pure eval can't run git, so <date> is the HEAD commit date (not a
  # real tag) and there is no commit-count — describe-SHAPED, not a true tag.
  # A dirty src/<repo> tree is invisible (inputs lock to the committed rev);
  # only the build-system tree's dirtiness shows, as `-dirty` on +build.
  #
  # Args (eval-time): upstreamVersion (parseM4Version/parseAcInitVersion),
  # srcInput (source flake input → .shortRev + .lastModifiedDate), forkUrl
  # (owner/repo from ./sources.nix), self (build-rev).
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

  # ==========================================================================
  # Derivation-attrs bundle
  # ==========================================================================

  # Shared reproducibility attrs — merge into mkDerivation with `//`.
  # The caller still owns preConfigure (because the version sed pattern
  # is autoconf-flavor-specific).  Compose the version string at eval
  # time via `composeVersion` and splice it into the caller's sed.
  mkReproAttrs = { pname, version }: {
    # -frandom-seed comes from nixpkgs' reproducible-builds.sh hook, as the
    # first 10 chars of ${NIX_OUTPATH_USED_AS_RANDOM_SEED:-$out}.  Override the
    # $out default: for a cross derivation $out is host-specific, which would
    # make the seed host-specific and break cross-host reproducibility.
    # Hashing `${pname}-${version}` keeps the 10-char-trimmed seed
    # host-independent yet distinct per target+build (a readable prefix would
    # be truncated to just the pname).  nix32 (nix's store-hash alphabet, no
    # symbols) avoids a `/` clashing with the hook's `${randSeed##*/}` trim.
    NIX_OUTPATH_USED_AS_RANDOM_SEED =
      "/" + builtins.convertHash {
        hash = builtins.hashString "sha256" "${pname}-${version}";
        hashAlgo = "sha256";
        toHashFormat = "nix32";
      };

    # Normalise the build-dir path embedded in DWARF.  Linux nix uses
    # /build; Darwin uses /nix/var/nix/builds/nix-<pid>-<rand>/.
    # Both get rewritten to /build so DWARF .debug_str / .debug_line_str
    # are byte-identical across hosts.
    preBuild = ''
      export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -fdebug-prefix-map=$NIX_BUILD_TOP=/build"
    '';
  };
}
