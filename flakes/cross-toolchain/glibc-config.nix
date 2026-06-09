# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared glibc-hurd configure flags (consumed by glibc.nix + the in-tree Makefile via
# dev-shell exports).  deployFlags pins the root-relative install dirs + the libc_cv_*
# cache vars to /lib - under --prefix=/ they would otherwise default to //lib.  Mirrors
# hurd-config.nix.

{
  # Always-on glibc-hurd configure flags (identical for nix + in-tree, independent
  # of the deployable prefix): the ctors-header cache var pre-declares the crt*.o
  # ctor-section detection (the link test it replaces needs a working libc).  NB:
  # profile + nscd are vanilla-on, which currently diverges the nix vs in-tree
  # build (l0 != l1).
  coreFlags = [
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
