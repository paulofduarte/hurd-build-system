#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# mig-drift gate comparator.  Reads two LLVM-IR text modules (pin-mig vs
# alias-mig stub IR) and reports stub functions whose RPC WIRE FACTS differ.
#
# Why a fact MANIFEST rather than an IR diff: an in-tree mig is wire-safe when it
# only reorders independent stores, and wire-BREAKING when it changes a message
# field's value/offset/type or the msgh_id.  A structural IR diff (llvm-diff) or
# even DiffKemp false-positives on the benign reorder; extracting an
# ORDER-INDEPENDENT SET of facts is precise by construction.
#
# Per function the manifest is the frozenset of:
#   ('st', byte-offset, type, value)  for each store into a message buffer,
#                                     where value = the constant, or 'arg<i>'
#                                     if it's the i-th routine argument (so an
#                                     arg->field remap is caught), else 'var';
#                                     offset is traced through i8 GEP chains.
#   ('call', callee, (const args))    for each mach_msg* call (catches changes
#                                     to message sizes / option flags).
# A reorder permutes the stores -> identical set; a changed constant/offset/type/
# arg-mapping or call-arg -> different set.
#
# Usage: mig-wire-manifest.py PIN.ll ALIAS.ll [--warn-only]
# Exit 0 if wire-equivalent (or --warn-only); 1 on divergence.
import re
import sys

_DEFINE = re.compile(r'define\b.*?@"?([A-Za-z0-9_.$]+)"?\((.*?)\)')
_GEP = re.compile(
    r'(%[\w.]+)\s*=\s*getelementptr\s+inbounds\s+i8,\s*ptr\s+(%[\w.]+),\s*i\d+\s+(-?\d+)')
_STORE = re.compile(r'store\s+(\S+)\s+([^,]+),\s*ptr\s+(%[\w.]+)')
_CALL = re.compile(r'call\s+\S+\s+@([\w.$]*mach_msg[\w.$]*)\((.*)\)')
_CONST = re.compile(r'-?\d+$|true$|false$|null$')
_INTARG = re.compile(r'i\d+\s+(-?\d+)')


def split_funcs(text):
    out, cur, body = {}, None, []
    for line in text.splitlines():
        m = _DEFINE.match(line)
        if m:
            cur = m.group(1)
            out[cur] = {'params': re.findall(r'%([A-Za-z0-9_.]+)', m.group(2))}
            body = []
        elif cur is not None and line.rstrip() == '}':
            out[cur]['body'] = '\n'.join(body)
            cur = None
        elif cur is not None:
            body.append(line)
    return out


def manifest(rec):
    body = rec.get('body', '')
    pidx = {p: i for i, p in enumerate(rec['params'])}
    gep = {}
    for m in _GEP.finditer(body):
        dst, base, off = m.group(1), m.group(2), int(m.group(3))
        bb, bo = gep.get(base, (base, 0))
        gep[dst] = (bb, bo + off)
    facts = set()
    for m in _STORE.finditer(body):
        ty, val, ptr = m.group(1), m.group(2).strip(), m.group(3)
        _, off = gep.get(ptr, (ptr, 0))
        if _CONST.match(val):
            v = val
        elif val.startswith('%') and val[1:] in pidx:
            v = 'arg%d' % pidx[val[1:]]
        else:
            v = 'var'
        facts.add(('st', off, ty, v))
    for m in _CALL.finditer(body):
        facts.add(('call', m.group(1), tuple(_INTARG.findall(m.group(2)))))
    return frozenset(facts)


def main(argv):
    pin = split_funcs(open(argv[1]).read())
    ali = split_funcs(open(argv[2]).read())
    warn = '--warn-only' in argv[3:]
    common = [f for f in pin if f in ali]
    diff = sorted(f for f in common if manifest(pin[f]) != manifest(ali[f]))
    print("  MIG-DRIFT    wire-fact manifest: %d/%d stub functions diverge under "
          "alias mig" % (len(diff), len(common)))
    for f in diff[:20]:
        print("    ! %s" % f)
    if len(diff) > 20:
        print("    ... and %d more" % (len(diff) - 20))
    if diff:
        if warn:
            print("  MIG-DRIFT    (HEADER_DRIFT_WARN_ONLY) continuing despite skew "
                  "- PIN BUMP NEEDED")
            return 0
        print("  MIG-DRIFT    PIN BUMP NEEDED (or HEADER_DRIFT_WARN_ONLY=1 to override)")
        return 1
    print("  MIG-DRIFT    ok: alias mig wire-equivalent to pin on every stub")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
