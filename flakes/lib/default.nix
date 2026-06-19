# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared helpers for the per-target derivations.  Barrel - the logic lives in
# sibling modules, grouped by concern:
#
#   parse-version.nix  - parse upstream versions from version.m4 / configure.ac
#                        (parseM4Version, parseAcInitVersion)
#   self-meta.nix      - metadata from the flake's `self` (buildRev, buildDate)
#   url.nix            - git hosting URL -> dotted fork-section identifier (shortUrl)
#   compose-version.nix - compose the full PACKAGE_VERSION string at flake eval
#                         (composeFromParts, composeVersion, composeToolchainVersion)
#   repro.nix          - mkDerivation attrs for host-independence (mkReproAttrs)

{ lib }:

let
  parseVersion = import ./parse-version.nix;
  selfMeta = import ./self-meta.nix;
  url = import ./url.nix { inherit lib; };
  composeVer = import ./compose-version.nix {
    inherit selfMeta url;
  };
  repro = import ./repro.nix;
  crossPkg = import ./cross-pkg.nix;
in

parseVersion // selfMeta // url // composeVer // repro // { inherit crossPkg; }
