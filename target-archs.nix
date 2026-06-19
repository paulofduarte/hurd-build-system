# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross targets we know how to build for.  Add an entry here to support a
# new target; the cross-toolchain, gnumach-headers, mig, and gnumach
# sub-flakes all consume from this attrset.  Dropping a target is a
# one-file edit here - nothing downstream hard-codes target names.
#
# Kept in its own root-level module (imported by flake.nix) so the
# toolchain-cache CI can path-filter on it: changing the target set affects
# which toolchains are built, but it stays separate from the package wiring.
#
#   crossTarget : the `<cpu>-gnu` Hurd triplet passed to the from-source cross
#                 toolchain (binutils/gcc `--target=`).  Drives the one
#                 cross-toolchain that builds both the gnumach kernel
#                 (freestanding, -nostdlib) and the Hurd userland.
#   platform    : "at" / "xen" - gnumach's --enable-platform=.  The "xen"
#                 entries are kernel-only variants that reuse their CPU
#                 sibling's userland toolchain (same crossTarget); the "at"
#                 entries get the full glibc-hurd + wrapped cc + Hurd userland.
{
  x86_64 = {
    crossTarget = "x86_64-gnu";
    platform = "at";
  };
  x86_64-xen = {
    crossTarget = "x86_64-gnu";
    platform = "xen";
  };
  i686 = {
    crossTarget = "i686-gnu";
    platform = "at";
  };
  i686-xen = {
    crossTarget = "i686-gnu";
    platform = "xen";
  };
}
