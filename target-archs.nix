# Cross targets we know how to build for.  Add an entry here to support a
# new target; the cross-toolchain, gnumach-headers, mig, and gnumach
# sub-flakes all consume from this attrset.
#
# Kept in its own root-level module (imported by flake.nix) so the
# toolchain-cache CI can path-filter on it: changing the target set affects
# which toolchains are built, but it stays separate from the package wiring.
#
#   crossSystem     : nixpkgs cross-system identifier for the gnumach
#                     KERNEL (freestanding *-elf bare-metal toolchain;
#                     consumed by flakes/cross-toolchain)
#   hurdCrossSystem : nixpkgs cross-system identifier for the Hurd
#                     USERLAND (hosted *-gnu toolchain; consumed by
#                     flakes/hurd-toolchain).  Optional — targets
#                     without it (aarch64 today, the xen variants)
#                     skip the Hurd userland chain.  Use the canonical
#                     2-tuple form `<cpu>-gnu` (Debian / cross-hurd /
#                     upstream gnumach convention).
#   migTarget       : the triple passed to MIG's --target= flag (CPU
#                     ABI; Xen variants share this with their non-Xen
#                     siblings)
#   platform        : value for gnumach's --enable-platform= ("at" /
#                     "xen" on x86; null where the option doesn't
#                     apply, e.g. aarch64)
{
  aarch64 = {
    crossSystem = "aarch64-none-elf";
    # No hurdCrossSystem yet — Sergey Bugaev's aarch64-gnu port is on
    # a personal branch, not upstream.  Add when it lands.
    migTarget   = "aarch64-gnu";
    platform    = null;
  };
  x86_64 = {
    crossSystem     = "x86_64-elf";
    hurdCrossSystem = "x86_64-gnu";
    migTarget       = "x86_64-gnu";
    platform        = "at";
  };
  x86_64-xen = {
    crossSystem = "x86_64-elf";
    # No hurdCrossSystem — xen variants share the same x86_64-gnu ABI
    # as their non-xen sibling; only gnumach's --enable-platform=xen
    # differs.  The userland builds once under `x86_64`.
    migTarget   = "x86_64-gnu";
    platform    = "xen";
  };
  i686 = {
    crossSystem     = "i686-elf";
    hurdCrossSystem = "i686-gnu";
    migTarget       = "i686-gnu";
    platform        = "at";
  };
  i686-xen = {
    crossSystem = "i686-elf";
    # No hurdCrossSystem — see x86_64-xen.
    migTarget   = "i686-gnu";
    platform    = "xen";
  };
}
