# Shared GNU Hurd configure flags, consumed by both the nix build
# (flakes/hurd) and the in-tree dev shell (dev-shell.nix) so the two
# build paths stay in lockstep.  `--host=<tp>` is added by the caller.
#
# `deployFlags` — the root-relative install dirs (the Hurd ships to /libexec,
# /sbin, /bin, … on a target Hurd; --prefix=/ makes the installed tree
# relocatable, consumed via DESTDIR/--sysroot).  Same set glibc uses, minus
# glibc's libc_cv_* (hurd has no slibdir/rtlddir to pin).
#
# Disables the optional external-dependency components (parted, rump,
# nfs/libtirpc, lwip, console xkbcommon, libgcrypt, libdaemon, libcrypt)
# so only the core ext2fs-bootable userland builds, and pre-seeds the
# cross-configure cache: hurd calls AC_NO_EXECUTABLES when cross-
# compiling, which makes modern autoconf reject the AC_CHECK_FUNCS link
# tests at configure.ac:154.  The six ac_cv_func_* values are the
# ground truth from glibc-hurd's symbol table (same for i686/x86_64);
# ac_cv_search_clnt_create=no dodges the libtirpc probe.

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
