# Distro image URLs — single source of truth.
#
# Both the parent Makefile's `run:` recipe and the `nix run` apps
# source this file, so a URL change here propagates to both build
# paths without drift.
#
# Naming uses our build-system convention (X86_64 / I686); where the
# upstream distro uses its own arch nomenclature, the mapping lives
# only inside the URL string itself.
#
# Debian: `latest/hurd-{amd64,i386}/debian-hurd.img.tar.gz` is a
# versionless 302 redirect to the most recently published dated
# image.  Cached copy doesn't auto-refresh; pass `RUN_REFRESH=1` to
# force a re-fetch.  Standalone modules (ext2fs.static, exec.static)
# live in the same dir.  Debian does NOT publish ld.so.1 standalone,
# and doesn't need it — exec.static is fully statically linked.
HURD_DEBIAN_X86_64_URL=https://cdimage.debian.org/cdimage/ports/latest/hurd-amd64/debian-hurd.img.tar.gz
HURD_DEBIAN_I686_URL=https://cdimage.debian.org/cdimage/ports/latest/hurd-i386/debian-hurd.img.tar.gz

# Gentoo: filename is stable, content rotates aperiodically when the
# Gentoo Hurd team publishes a fresh snapshot.  `RUN_REFRESH=1` to
# force a re-fetch.
HURD_GENTOO_X86_64_URL=https://distfiles.gentoo.org/experimental/amd64/hurd/hurd-x86_64-preview.qcow2
HURD_GENTOO_I686_URL=https://distfiles.gentoo.org/experimental/x86/hurd/hurd-i686-preview.qcow2

# Guix: /search/latest/image is Cuirass's auto-latest endpoint —
# server-side redirect to the most recent successful build.  Note
# that `system:x86_64-linux` refers to the BUILD HOST (Guix only
# operates x86_64-linux build farms for Hurd images), NOT the target
# arch — the target arch is encoded only in the qcow2 filename.
# hurd64-barebones.qcow2 artefacts are aggressively GC'd by Guix
# CI; expect 500 most of the time for x86_64.
HURD_GUIX_I686_URL='https://ci.guix.gnu.org/search/latest/image?query=spec:images+status:success+system:x86_64-linux+hurd-barebones.qcow2'
HURD_GUIX_X86_64_URL='https://ci.guix.gnu.org/search/latest/image?query=spec:images+status:success+system:x86_64-linux+hurd64-barebones.qcow2'
