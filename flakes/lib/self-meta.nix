# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Metadata derived from the flake's `self` - the build-system repo's
# short rev and commit date, in a form composeVersion expects.

{
  # Build-system rev - `<short>` when clean, `<short>-dirty` when dirty.
  # Nix already appends `-dirty` itself, so this is just an `or` chain.
  buildRev = self: self.shortRev or self.dirtyShortRev or "unknown";

  # Build-system date as YYYYMMDD.  Available even on dirty trees.
  buildDate = self: builtins.substring 0 8 (self.lastModifiedDate or "00000000");
}
