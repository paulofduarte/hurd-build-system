# Shared determinism build flags for the cross builds — consumed by the nix
# kernel/userland builds (flakes/gnumach, flakes/hurd) AND the in-tree dev
# shell (dev-shell.nix), so gnumach/hurd/glibc come out byte-identical on
# every host.  Two host-varying inputs otherwise leak into the output:
#
#   1. The cross-toolchain's own /nix/store paths — gcc's internal `include`
#      and `sys-include` dirs — recorded in DWARF (.debug_str/.debug_line_str,
#      and referenced from .debug_info).  The store hash differs per host
#      (nix input-addresses the cross-gcc per build platform), so the same
#      source yields different DWARF on each host.  `debugPrefixMap` rewrites
#      each toolchain path to a stable name; the values are arbitrary, only
#      their stability matters, and debug info stays usable (paths only).
#
#   2. gcc's `-frandom-seed`, which nixpkgs' reproducible-builds setup hook
#      (pkgs/build-support/setup-hooks/reproducible-builds.sh) derives from
#      $out — host-varying for our cross derivations and the dev shell, since
#      the toolchain input's store hash differs per host.  The seed feeds
#      gcc's symbol-name uniquifier, perturbing .text/.rodata of seed-sensitive
#      TUs (all of glibc + the hurd servers).  Pin it to `randomSeed`.  No
#      runtime-security impact: it is compile-time symbol naming only, not
#      runtime entropy (stack canary, ASLR, RELRO/PIE are all independent).

{ lib }:

rec {
  # Stable names for a wrapped toolchain's three store paths.  `toolchain` is
  # a `wrapCCWith` result, so `.cc` is the underlying gcc (the one whose
  # include dirs leak) and `.bintools` the wrapped binutils.
  debugPrefixMap = toolchain: [
    "-fdebug-prefix-map=${toolchain}=/cross-cc-wrapper"
    "-fdebug-prefix-map=${toolchain.cc}=/cross-gcc"
    "-fdebug-prefix-map=${toolchain.bintools}=/cross-binutils-wrapper"
  ];

  debugPrefixMapStr = toolchain: lib.concatStringsSep " " (debugPrefixMap toolchain);

  # Fixed cross-build random seed, replacing the host-varying one the
  # reproducible-builds hook derives from $out.
  randomSeed = "gnu-hurd-cross";
}
