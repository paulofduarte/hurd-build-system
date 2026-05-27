# Shared helpers used by every per-target derivation (gnumach, mig, and
# any future ones — hurd, glibc, …).
#
# Two responsibilities:
#
#   1. Compose a richly-versioned, byte-deterministic build.  Each binary
#      ends up with PACKAGE_VERSION set to a 5-component string:
#        <upstream>+<date>+<fork-id>+<src-hash>+build+<build-hash>
#      …pinned `-frandom-seed`, and a normalised build dir in DWARF.
#
#   2. Keep the per-derivation .nix files small.  Sub-flakes import these
#      helpers, compose a version string at flake-eval time, and feed it
#      to a per-derivation `versionSedExpr` to splice it into autoconf.
#
# Data sources for the version components (all read at flake eval, all
# pure — no impure flag needed, no in-sandbox git):
#
#   upstream version  — parsed from version.m4 / configure.ac via
#                       builtins.readFile (`parseM4Version`,
#                       `parseAcInitVersion`)
#   <date>            — `<srcInput>.lastModifiedDate` (YYYYMMDD subset)
#   <fork-id>         — parsed from .gitmodules entry for the submodule
#                       (`parseGitmodulesUrl` + `parseForkId`)
#   <src-hash>        — `<srcInput>.shortRev`
#   <build-hash>      — `self.shortRev or self.dirtyShortRev`
#
# `<srcInput>` is a separate flake input pointing at the same submodule
# worktree (`git+file:./src/<repo>`).  nix flakes don't vendor `.git`
# under any `submodules=1` setting, so this was the only way to expose
# submodule commit metadata to pure eval.  See flake.nix for the
# declarations.  By design, src-hash always reflects a *committed* rev
# — uncommitted edits inside src/<repo> aren't visible to the input.

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
  # Eval-time helpers — parse .gitmodules for the fork-id URL
  # ==========================================================================

  # ==========================================================================
  # .gitmodules parsing — pulls `url = …` / `branch = …` for one submodule
  # ==========================================================================
  #
  # The submodule's *declared* URL + branch live in .gitmodules — the
  # in-tree `.git/config` can drift but doesn't survive into the vendored
  # self.outPath.  These parsers tolerate the tab/space mix git writes.

  _gitmodulesField = { content, submodulePath, field }:
    let
      # ERE: match the [submodule "<path>"] header, then arbitrary
      # non-bracket chars (everything up to the NEXT submodule block),
      # then `<field> = <value>` on its own line.  Nix's `.` matches
      # newlines, so no multi-line dance needed.
      pattern = ".*[[]submodule \"${submodulePath}\"[]][^[]*${field}[ \t]*=[ \t]*([^ \t\n]+).*";
      match = builtins.match pattern content;
    in
    if match == null then "" else builtins.head match;

  parseGitmodulesUrl    = { content, submodulePath }:
    _gitmodulesField { inherit content submodulePath; field = "url"; };
  parseGitmodulesBranch = { content, submodulePath }:
    _gitmodulesField { inherit content submodulePath; field = "branch"; };

  # ==========================================================================
  # URL → dotted-identifier short form
  # ==========================================================================
  #
  # Parses common git hosting URLs into a dotted identifier string suitable
  # for embedding in semver build metadata (Style B2):
  #
  #   github URLs → "github.<owner>.<repo>[.<branch>]"
  #   gitlab URLs → "gitlab.<owner>.<repo>[.<branch>]"
  #   codeberg    → "codeberg.<owner>.<repo>[.<branch>]"
  #   savannah    → "savannah.<project>.<repo>[.<branch>]"
  #   any other   → "unknown.<branch?>"  (hostnames never leak)
  #
  # Each `.`-separated piece is one semver build-metadata identifier
  # (`[0-9A-Za-z-]`).  Branch is included only when non-empty.

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

  # Build a dotted short identifier from a URL and an optional branch.
  shortUrl = { url, branch ? "" }:
    let
      parsed = _parseUrl url;
      base = if parsed == null
             then "unknown"
             else "${parsed.type}.${parsed.owner}.${parsed.repo}";
    in
    if branch == "" then base else "${base}.${branch}";

  # ==========================================================================
  # Compose the full version string at flake eval (no shell needed)
  # ==========================================================================

  # Returns the PACKAGE_VERSION as a plain string in Style B2:
  #
  #   <upstream>+<date>.<short-url>.g<src>.build.g<build>[-dirty]
  #
  # where `<short-url>` is `<type>.<owner>.<repo>[.<branch>]` (see
  # `shortUrl`).  Every `.` is an identifier boundary; every `-` is
  # inside a single identifier.  Strict semver-compliant.
  #
  # Example clean:
  #   1.8+20260523.github.paulofduarte.gnumach.aarch64-tests.g79f3013.build.ga16f9a6
  #
  # Example with build-system dirty (the `-dirty` suffix comes from
  # `self.dirtyShortRev` automatically):
  #   1.8+20260523.github.paulofduarte.gnumach.aarch64-tests.g79f3013.build.ga16f9a6-dirty
  #
  # NB: src-tree dirty is NOT detected.  Flake inputs lock to the
  # committed rev; uncommitted edits in src/<repo> aren't visible to
  # pure flake eval.  See flake.nix for the design discussion.
  #
  # Args (all eval-time):
  #   upstreamVersion : "1.8" etc.  Use `parseM4Version` or
  #                     `parseAcInitVersion` to extract.
  #   srcInput        : parallel flake input (e.g. inputs.gnumach-src)
  #                     pointing at the submodule.  Provides .shortRev
  #                     and .lastModifiedDate.
  #   submodulePath   : .gitmodules key (e.g. "src/gnumach").
  #   self            : the flake's `self`, for build-rev.
  composeVersion = {
    upstreamVersion,
    srcInput,
    submodulePath,
    self,
  }:
    let
      srcShort = srcInput.shortRev or "unknown";
      srcDate  = builtins.substring 0 8 (srcInput.lastModifiedDate or "00000000");
      gitmodules = builtins.readFile (self.outPath + "/.gitmodules");
      url = parseGitmodulesUrl { content = gitmodules; inherit submodulePath; };
      branch = parseGitmodulesBranch { content = gitmodules; inherit submodulePath; };
      short  = shortUrl { inherit url branch; };
      buildShort = buildRev self;
    in
    "${upstreamVersion}+${srcDate}.${short}.g${srcShort}.build.g${buildShort}";

  # ==========================================================================
  # Derivation-attrs bundle
  # ==========================================================================

  # Shared reproducibility attrs — merge into mkDerivation with `//`.
  # The caller still owns preConfigure (because the version sed pattern
  # is autoconf-flavor-specific).  Compose the version string at eval
  # time via `composeVersion` and splice it into the caller's sed.
  mkReproAttrs = { self, pname }: {
    # Pin -frandom-seed via nixpkgs' reproducible-builds.sh hook.
    # Per-derivation prefix differentiates seeds (so e.g. gnumach and
    # mig don't share .debug_str bucket order with each other).
    NIX_OUTPATH_USED_AS_RANDOM_SEED = "/${pname}-${buildRev self}";

    # Normalise the build-dir path embedded in DWARF.  Linux nix uses
    # /build; Darwin uses /nix/var/nix/builds/nix-<pid>-<rand>/.
    # Both get rewritten to /build so DWARF .debug_str / .debug_line_str
    # are byte-identical across hosts.
    preBuild = ''
      export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -fdebug-prefix-map=$NIX_BUILD_TOP=/build"
    '';
  };
}
