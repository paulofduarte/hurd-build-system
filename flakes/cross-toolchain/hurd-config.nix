# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared GNU Hurd configure flags (nix build + in-tree dev shell, kept in lockstep);
# `--host=<tp>` is added by the caller.
#
# deployFlags - usr-merged install dirs under /usr; the tree stays relocatable via
# DESTDIR.  Same set as glibc, minus its libc_cv_*.  NOTE the servers dir is NOT
# under /usr: config.make.in sets `hurddir = ${exec_prefix}/hurd` -> /usr/hurd under
# --prefix=/usr, but the boot chain + distro overlays expect servers at top-level
# /hurd (Debian keeps /hurd real, unmerged), so the caller pins `hurddir=/hurd` as a
# make-var override at build+install time (see flakes/hurd/default.nix + Makefile).
# The /lib,/bin,/sbin -> /usr/* compat symlinks are added at dist-tree assembly.
#
# coreFlags - disables the optional external-dependency components (parted, rump,
# nfs/libtirpc, lwip, xkbcommon, libgcrypt, libdaemon, libcrypt) so only the core
# ext2fs-bootable userland builds.  The ac_cv_* vars are pre-seeded because hurd's
# cross AC_NO_EXECUTABLES makes autoconf reject the AC_CHECK_FUNCS link tests; the
# ac_cv_func_* are ground truth from glibc-hurd's symbols, ac_cv_search_clnt_create=no
# dodges libtirpc.

{
  deployFlags = [
    "--prefix=/usr"
    "--libexecdir=/usr/libexec"
    "--bindir=/usr/bin"
    "--sbindir=/usr/sbin"
    "--sysconfdir=/etc"
    "--localstatedir=/var"
    "--libdir=/usr/lib"
    "--includedir=/usr/include"
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
