# Shared glibc-hurd configure flags (consumed by glibc.nix + the in-tree Makefile via
# dev-shell exports).  deployFlags pins the root-relative install dirs + the libc_cv_*
# cache vars to /lib — under --prefix=/ they would otherwise default to //lib.  Mirrors
# hurd-config.nix.

{
  # Always-on glibc-hurd configure flags (identical for nix + in-tree, independent
  # of the deployable prefix): the libpthread add-on, obsolete-rpc, the disables,
  # and the ctors-header cache var.
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
