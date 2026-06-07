# Patched texinfo (deterministic install-info).  compare_entries_text() is an
# inconsistent qsort comparator for case-only-different, equal-length menu names
# (e.g. `_Exit` vs `_exit` in libc.info): it returns -1 for BOTH (a,b) and (b,a),
# so qsort's output is undefined and differs across libc qsort impls, making
# share/info/dir non-reproducible cross-host.  The patch breaks the tie
# case-sensitively (a total order).  (makeinfo is unaffected.)
#
# Shared (DRY) by the dev-shell — the in-tree install-info — AND glibc.nix — the
# nix glibc's OWN `make install` install-info — so whichever build produces
# share/info/dir, it is deterministic cross-host AND byte-identical between the
# in-tree and nix glibc.  Without it in glibc.nix the nix glibc ships a `dir` built
# by the buggy upstream install-info (wrong default header + a host-dependent sort),
# which dist-glibc-nix then copies into the dist.
{ pkgs }:

pkgs.texinfo.overrideAttrs (old: {
  patches = (old.patches or [])
    ++ [ ./patches/texinfo-install-info-total-order-compare.patch ];
  # Patching install-info.c bumps its mtime, which would make `make` try to
  # regenerate the shipped man page via help2man (not a build input) ->
  # "install-info.1 Error 127".  Touch the prebuilt page so it stays current.
  postPatch = (old.postPatch or "") + ''
    touch man/install-info.1
  '';
})
