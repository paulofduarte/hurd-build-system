# Shared helpers used by every per-target derivation (gnumach, mig, and
# any future ones — hurd, glibc, …).  This file is a barrel — the actual
# logic lives in sibling modules, grouped by concern:
#
#   parse-version.nix  — parse upstream version strings from version.m4
#                        / configure.ac (parseM4Version, parseAcInitVersion)
#   self-meta.nix      — derive metadata from the flake's `self`
#                        (buildRev, buildDate)
#   url.nix            — turn a git hosting URL into a dotted identifier
#                        for the version's fork section (shortUrl)
#   compose-version.nix — compose the full PACKAGE_VERSION string at flake
#                         eval (composeFromParts, composeVersion,
#                         composeToolchainVersion)
#   repro.nix          — mkDerivation attrs that make the build host-
#                        independent (mkReproAttrs)
#
# The PACKAGE_VERSION format itself is documented in compose-version.nix
# and the README "Versioning" section.

{ lib }:

let
  parseVersion = import ./parse-version.nix { inherit lib; };
  selfMeta     = import ./self-meta.nix     { inherit lib; };
  url          = import ./url.nix           { inherit lib; };
  composeVer   = import ./compose-version.nix {
    inherit lib selfMeta url;
  };
  repro        = import ./repro.nix         { inherit lib; };
  crossPkg     = import ./cross-pkg.nix     { inherit lib; };
in

parseVersion // selfMeta // url // composeVer // repro // { inherit crossPkg; }
