# Shared glibc-hurd DEPLOYABLE (--prefix=/) configure flags — the root-relative
# install dirs + the `libc_cv_*` cache vars that pin slibdir/rtlddir/complocaledir/
# etc. to `/` (under --prefix=/ they would otherwise default to $(exec_prefix)/lib
# = //lib; the AC_SUBST'd cache vars set them straight).  Consumed by BOTH the nix
# build (flakes/cross-toolchain/glibc.nix) and the in-tree Makefile (via the
# dev-shell GLIBC_DEPLOY_FLAGS export), so the two build paths stay byte-identical
# and the set lives in ONE place.  Mirrors hurd-config.nix.  Order matches glibc.nix's
# original inline set (keeps that derivation drvPath-identical across the extraction).

{
  # Always-on glibc-hurd configure flags (identical for nix + in-tree, independent
  # of the deployable prefix): the libpthread add-on, obsolete-rpc, the disables,
  # and the ctors-header cache var.  Order matches glibc.nix's original inline set.
  coreFlags = [
    "--enable-add-ons=libpthread"
    "--enable-obsolete-rpc"
    "--disable-profile"
    "--disable-nscd"
    "--disable-werror"
    "--disable-multilib"
    "libc_cv_ctors_header=yes"
  ];

  deployFlags = [
    "--libdir=/lib"
    "--sysconfdir=/etc"
    "--datarootdir=/share"
    "--localstatedir=/var"
    "--sbindir=/sbin"
    "--bindir=/bin"
    "--libexecdir=/libexec"
    "--includedir=/include"
    "libc_cv_slibdir=/lib"
    "libc_cv_rtlddir=/lib"
    "libc_cv_complocaledir=/lib/locale"
    "libc_cv_sysconfdir=/etc"
    "libc_cv_localstatedir=/var"
    "libc_cv_rootsbindir=/sbin"
  ];
}
