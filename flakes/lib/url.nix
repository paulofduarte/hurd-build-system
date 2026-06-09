# URL -> dotted-identifier short form, for the fork/remote section of the
# composed version string (see compose-version.nix):
#
#   github URLs -> "github.<owner>.<repo>"
#   gitlab URLs -> "gitlab.<owner>.<repo>"
#   codeberg    -> "codeberg.<owner>.<repo>"
#   savannah    -> "savannah.<project>.<repo>"
#   sourceware  -> "sourceware.<repo>"  (no owner - sourceware hosts
#                                       projects flat under git/)
#   any other   -> "unknown"  (hostnames never leak)
#
# Each `.`-separated piece is one semver build-metadata identifier
# (`[0-9A-Za-z-]`).

{ lib }:

let
  parseUrl = url:
    let
      cleanUrl = lib.removeSuffix ".git" url;
      patterns = [
        { type = "github";     re = "https?://github[.]com/([^/]+)/([^/]+)"; }
        { type = "gitlab";     re = "https?://gitlab[.]com/([^/]+)/([^/]+)"; }
        { type = "codeberg";   re = "https?://codeberg[.]org/([^/]+)/([^/]+)"; }
        { type = "savannah";   re = "https?://git[.]savannah[.]gnu[.]org/git/([^/]+)/([^/]+)"; }
        # sourceware.org has flat layout - no owner segment.
        { type = "sourceware"; re = "https?://sourceware[.]org/git/([^/]+)"; ownerless = true; }
      ];
      tryOne = acc: p:
        if acc != null then acc
        else
          let m = builtins.match p.re cleanUrl; in
          if m == null then null
          else if p.ownerless or false then
            { type = p.type; owner = null; repo = builtins.elemAt m 0; }
          else
            { type = p.type; owner = builtins.elemAt m 0; repo = builtins.elemAt m 1; };
    in
    builtins.foldl' tryOne null patterns;
in

{
  shortUrl = { url }:
    let parsed = parseUrl url; in
    if parsed == null
    then "unknown"
    else if parsed.owner == null
    then "${parsed.type}.${parsed.repo}"
    else "${parsed.type}.${parsed.owner}.${parsed.repo}";
}
