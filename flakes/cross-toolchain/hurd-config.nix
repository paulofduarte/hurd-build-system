# Shared GNU Hurd configure flags (nix build + in-tree dev shell, kept in lockstep);
# `--host=<tp>` is added by the caller.
#
# deployFlags — root-relative install dirs; --prefix=/ makes the tree relocatable.
# Same set as glibc, minus its libc_cv_*.
#
# coreFlags — disables the optional external-dependency components (parted, rump,
# nfs/libtirpc, lwip, xkbcommon, libgcrypt, libdaemon, libcrypt) so only the core
# ext2fs-bootable userland builds.  The ac_cv_* vars are pre-seeded because hurd's
# cross AC_NO_EXECUTABLES makes autoconf reject the AC_CHECK_FUNCS link tests; the
# ac_cv_func_* are ground truth from glibc-hurd's symbols, ac_cv_search_clnt_create=no
# dodges libtirpc.

{
  deployFlags = [
    "--prefix=/"
    "--libexecdir=/libexec"
    "--bindir=/bin"
    "--sbindir=/sbin"
    "--sysconfdir=/etc"
    "--localstatedir=/var"
    "--libdir=/lib"
    "--includedir=/include"
  ];

  coreFlags = [
    "--disable-profile"
    "--without-parted"
    "--without-libbz2"
    "--without-libz"
    "--without-rump"
    "--without-libtirpc"
    "--without-libdaemon"
    "--without-libcrypt"
    "--disable-ncursesw"
    "ac_cv_search_clnt_create=no"
    "ac_cv_func_file_exec_paths=yes"
    "ac_cv_func_exec_exec_paths=yes"
    "ac_cv_func__hurd_exec_paths=yes"
    "ac_cv_func__hurd_libc_proc_init=yes"
    "ac_cv_func_mach_port_set_ktype=no"
    "ac_cv_func_file_utimens=yes"
  ];
}
