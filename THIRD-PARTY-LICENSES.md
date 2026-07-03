<!--
SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Third-party licenses

This build system is original glue licensed `GPL-3.0-or-later` (see
[LICENSE](LICENSE) and the per-file SPDX headers). It does not vendor any
third-party source: every component below is fetched at build time, by
pinned revision or by URL+SHA256, and retains its own upstream license.
Nothing here relicenses any of them. This file is an informational map of
what gets pulled in and under what terms; it is not itself a license grant.

The in-tree patches under `flakes/*/patches/` are derivative works of their
respective upstreams and are labelled with the upstream license in
[REUSE.toml](REUSE.toml), not with the build glue's license.

## Components built into the GNU/Hurd artifact

Pinned in `flake.nix` (the `*-src` inputs) and built by the flakes under
`flakes/`.

| Component | Upstream | License |
|-----------|----------|---------|
| GNU Hurd | git.savannah.gnu.org/hurd/hurd | GPL-2.0-or-later |
| GNU Mach | git.savannah.gnu.org/hurd/gnumach | CMU-permissive (Mach heritage) + GPL-2.0 / GPL-2.0-or-later |
| GNU MIG | git.savannah.gnu.org/hurd/mig | CMU-permissive core + GPL-2.0-or-later build/test files |
| GNU C Library (glibc) | sourceware.org/git/glibc | LGPL-2.1-or-later, with BSD/permissive portions (see glibc `LICENSES`) |
| zlib | zlib.net (madler/zlib) | Zlib |
| libpciaccess | gitlab.freedesktop.org/xorg/lib/libpciaccess | MIT/X11 |
| libacpica (Intel ACPICA) | salsa.debian.org/hurd-team/libacpica (ACPICA 20220331 + Hurd glue) | GPL-2.0 / Intel BSD-style dual; glue GPL-2.0-or-later |

GNU Mach contains files marked "version 2" with no "or later" clause, so the
kernel as a whole is effectively GPL-2.0-only and cannot be relicensed to
GPLv3. This is fine for a kernel and does not affect the build glue.

## Build toolchain (from nixpkgs)

Used to build the components above; not part of the produced artifact except
where noted.

| Tool | License | Note |
|------|---------|------|
| GCC | GPL-3.0-or-later | `libgcc_s` / `libstdc++` link into outputs under the GCC Runtime Library Exception, which does not impose GPLv3 on the result |
| GNU binutils | GPL-3.0-or-later | build-time only |
| GNU texinfo | GPL-3.0-or-later | documentation generation only |
| gmp / mpfr / mpc / isl | LGPL-3.0+ / LGPL-2.1+ | GCC math dependencies, build-time |
| nixpkgs | MIT | provides the build environment and the wrappers |

## Test and image tooling (sidekick VM)

Fetched only for the test harness and image assembly; never shipped in the
toolchain artifact. Pins live in `flakes/sidekick/`.

| Source | License | Pin |
|--------|---------|-----|
| Alpine `linux-virt` kernel | GPL-2.0-only (Linux) | `packages.nix` (APK SHA256) |
| Debian tool closure (busybox, grub, xorriso, mtools, e2fsprogs, libabigail/abigail-tools, pahole, and their dependency closure) | mixed GPL-2.0 / GPL-3.0 / LGPL per package | `debian-packages.nix` (snapshot.debian.org URL+SHA256) |

The Debian closure is enumerated in `flakes/sidekick/debian-packages.nix`,
which is generated factual data (marked `CC0-1.0`). For the exact license of
any individual `.deb`, consult that package's `/usr/share/doc/<pkg>/copyright`
in the Debian archive.
