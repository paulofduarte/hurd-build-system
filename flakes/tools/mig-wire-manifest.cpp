// SPDX-FileCopyrightText: 2026 Paulo Duarte <paulofernandobd@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// rpc-wire-drift gate comparator.  Reads two LLVM-IR modules (pin-mig vs alias-mig
// stub IR) and reports stub functions whose RPC WIRE FACTS differ.
//
// Why a fact MANIFEST rather than an IR diff: an in-tree mig is wire-safe when
// it only reorders independent stores, and wire-BREAKING when it changes a
// field's value/offset/type, the msgh_id, the OOL marshalling, or a mach_msg
// call arg.  A structural IR diff (llvm-diff / DiffKemp) false-positives on the
// benign reorder; extracting an ORDER-INDEPENDENT SET of facts is precise.
//
// Per function the manifest is a sorted set of fact strings:
//   "st@<base>+<off>:<ty>=<valexpr>"     a store into a message buffer
//   "mc@<base>+<off>=<lenexpr><-<src>"   an llvm.memcpy (OOL / bulk copy)
//   "call:<callee>(<argexprs>)"          a marshalling call: mach_msg* / __mig_*
//                                        OR any call passing a ptr into the buffer
// where <valexpr> is a CANONICAL, name-independent expression of the value:
//   constant -> c<N>, argument -> a<argno>, load -> ld(<base>+<off>),
//   any other instruction -> <opcode>(<operand exprs>)  (depth-capped).
// <base> is the GEP root, normalised to a<argno> / k<alloca-index> / g:<name>,
// reorder-stable.  Offsets come from GEPOperator::accumulateConstantOffset, so
// typed and i8 GEP chains both resolve.
//
// Captures: msgh_id & constant fields (#0), arg->field remap (#2a), value
// recomputation of variable fields (#2b), OOL/memcpy marshalling (#1, both the
// llvm.memcpy intrinsic and __mig_memcpy/__mig_strncpy/__mig_{,de}allocate, plus
// ANY non-llvm call passing a pointer into the message buffer - so an
// un-enumerated payload helper is still caught), mach_msg call args (#3).  A
// reorder permutes the set -> no change.
//
// Usage: mig-wire-manifest PIN.{bc,ll} ALIAS.{bc,ll} [--warn-only]
// Exit 0 if wire-equivalent (or --warn-only); 1 on divergence.
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"
#include <map>
#include <memory>
#include <set>
#include <string>

using namespace llvm;

namespace {

// Stable per-function id for a GEP root: args/allocas/globals don't move under a
// store reorder, so these ids are reorder-invariant.
struct BaseNamer {
  std::map<const Value *, std::string> cache;
  std::map<const AllocaInst *, int> allocaIdx;
  explicit BaseNamer(const Function &F) {
    int i = 0;
    for (const auto &I : instructions(F))
      if (auto *A = dyn_cast<AllocaInst>(&I)) allocaIdx[A] = i++;
  }
  std::string of(const Value *v) {
    auto it = cache.find(v);
    if (it != cache.end()) return it->second;
    std::string s;
    if (auto *A = dyn_cast<Argument>(v))
      s = "a" + std::to_string(A->getArgNo());
    else if (auto *Al = dyn_cast<AllocaInst>(v))
      s = "k" + std::to_string(allocaIdx[Al]);
    else if (auto *G = dyn_cast<GlobalValue>(v))
      s = "g:" + G->getName().str();
    else
      s = "?";
    cache[v] = s;
    return s;
  }
};

// Walk the GEP chain, summing constant offsets; return (root, byte offset).
std::pair<const Value *, int64_t> baseOff(const Value *v, const DataLayout &DL) {
  int64_t off = 0;
  while (auto *G = dyn_cast<GEPOperator>(v)) {
    APInt a(DL.getIndexSizeInBits(G->getPointerAddressSpace()), 0);
    if (!G->accumulateConstantOffset(DL, a)) break;
    off += a.getSExtValue();
    v = G->getPointerOperand();
  }
  return {v, off};
}

std::string tyStr(Type *t) {
  std::string s;
  raw_string_ostream os(s);
  t->print(os);
  return os.str();
}

std::string ptrExpr(const Value *p, const DataLayout &DL, BaseNamer &bn) {
  auto bo = baseOff(p, DL);
  return bn.of(bo.first) + "+" + std::to_string(bo.second);
}

// Just the GEP-root id (no offset) - used to tell whether a pointer aims at the
// message buffer (a base that receives stores).
std::string baseId(const Value *p, const DataLayout &DL, BaseNamer &bn) {
  return bn.of(baseOff(p, DL).first);
}

// Canonical, name-independent expression of a value (depth-capped).
std::string valExpr(const Value *v, const DataLayout &DL, BaseNamer &bn, int depth) {
  if (auto *C = dyn_cast<ConstantInt>(v))
    return "c" + (C->getBitWidth() <= 64 ? std::to_string(C->getSExtValue())
                                         : std::string("big"));
  if (isa<ConstantPointerNull>(v)) return "null";
  // Any pointer value (alloca / GEP / arg / global) -> base+offset, so a
  // message-buffer pointer is keyed the same way a store's destination is and
  // an offset/aliasing shift in a mach_msg buffer arg becomes visible.
  if (v->getType()->isPointerTy()) return "p[" + ptrExpr(v, DL, bn) + "]";
  if (auto *A = dyn_cast<Argument>(v)) return "a" + std::to_string(A->getArgNo());
  if (auto *C = dyn_cast<Constant>(v)) return "C:" + tyStr(C->getType());
  if (depth <= 0) return "...";
  if (auto *L = dyn_cast<LoadInst>(v))
    return "ld(" + ptrExpr(L->getPointerOperand(), DL, bn) + ")";
  if (auto *I = dyn_cast<Instruction>(v)) {
    std::string s = std::string(I->getOpcodeName()) + "(";
    bool first = true;
    for (const Use &u : I->operands()) {
      if (!first) s += ",";
      first = false;
      s += valExpr(u.get(), DL, bn, depth - 1);
    }
    return s + ")";
  }
  return "?";
}

// Calls that carry wire marshalling.  mach_msg* is the send/recv primitive
// (sizes/options); the __mig_* helpers move the actual payload: __mig_memcpy /
// __mig_strncpy do OOL & string copies, __mig_allocate / __mig_deallocate set
// up OOL buffers.  Reply-port bookkeeping (__mig_{get,put,dealloc}_reply_port)
// and llvm.lifetime.* are local, not wire - excluded.  Note "__mig_deallocate"
// is NOT a substring of "__mig_dealloc_reply_port", so the contains() is safe.
bool isWireCall(StringRef n) {
  return n.contains("mach_msg") || n.contains("__mig_memcpy") ||
         n.contains("__mig_strncpy") || n.contains("__mig_allocate") ||
         n.contains("__mig_deallocate");
}

std::set<std::string> manifest(Function &F) {
  const DataLayout &DL = F.getParent()->getDataLayout();
  BaseNamer bn(F);
  // Pass 1: the bases that receive stores ARE the message buffer(s).  Any later
  // call that passes a pointer into one of them is marshalling the wire, even if
  // it is not on the isWireCall allow-list - this catches an OOL/payload helper
  // we have not enumerated (a new __mig_*, a custom copy routine, ...) without a
  // name list.  Bookkeeping calls (reply-port helpers take an i32, not a buffer
  // pointer) stay out.
  std::set<std::string> bufBases;
  for (auto &I : instructions(F))
    if (auto *S = dyn_cast<StoreInst>(&I))
      bufBases.insert(baseId(S->getPointerOperand(), DL, bn));
  std::set<std::string> facts;
  for (auto &I : instructions(F)) {
    if (auto *S = dyn_cast<StoreInst>(&I)) {
      facts.insert("st@" + ptrExpr(S->getPointerOperand(), DL, bn) + ":" +
                   tyStr(S->getValueOperand()->getType()) + "=" +
                   valExpr(S->getValueOperand(), DL, bn, 6));
    } else if (auto *M = dyn_cast<MemCpyInst>(&I)) {
      facts.insert("mc@" + ptrExpr(M->getDest(), DL, bn) + "=" +
                   valExpr(M->getLength(), DL, bn, 4) + "<-" +
                   ptrExpr(M->getSource(), DL, bn));
    } else if (auto *Cl = dyn_cast<CallInst>(&I)) {
      const Function *cf = Cl->getCalledFunction();
      if (!cf) continue;
      StringRef nm = cf->getName();
      if (nm.starts_with("llvm.")) continue; // intrinsics: effect flows via args
      bool wire = isWireCall(nm);
      if (!wire)
        for (const Use &u : Cl->args())
          if (u.get()->getType()->isPointerTy() &&
              bufBases.count(baseId(u.get(), DL, bn))) { wire = true; break; }
      if (wire) {
        std::string s = "call:" + nm.str() + "(";
        bool first = true;
        for (const Use &u : Cl->args()) {
          if (!first) s += ",";
          first = false;
          s += valExpr(u.get(), DL, bn, 6);
        }
        facts.insert(s + ")");
      }
    }
  }
  return facts;
}

std::unique_ptr<Module> load(const char *path, LLVMContext &ctx) {
  SMDiagnostic err;
  auto m = parseIRFile(path, err, ctx);
  if (!m) {
    err.print("mig-wire-manifest", errs());
    exit(2);
  }
  return m;
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    errs() << "usage: mig-wire-manifest PIN ALIAS [--warn-only]\n";
    return 2;
  }
  bool warn = false;
  for (int i = 3; i < argc; i++)
    if (std::string(argv[i]) == "--warn-only") warn = true;

  LLVMContext ctx;
  auto pin = load(argv[1], ctx), ali = load(argv[2], ctx);

  std::map<std::string, std::set<std::string>> pm;
  for (auto &F : *pin)
    if (!F.isDeclaration()) pm[F.getName().str()] = manifest(F);

  int common = 0, diverge = 0;
  std::set<std::string> diffNames;
  for (auto &F : *ali) {
    if (F.isDeclaration()) continue;
    auto it = pm.find(F.getName().str());
    if (it == pm.end()) continue;
    common++;
    if (it->second != manifest(F)) {
      diverge++;
      diffNames.insert(F.getName().str());
    }
  }

  outs() << "  RPC-DRIFT    wire-fact manifest: " << diverge << "/" << common
         << " stub functions diverge under alias mig\n";
  int shown = 0;
  for (const auto &n : diffNames) {
    if (shown++ >= 20) break;
    outs() << "    ! " << n << "\n";
  }
  if ((int)diffNames.size() > 20)
    outs() << "    ... and " << (diffNames.size() - 20) << " more\n";

  if (diverge) {
    if (warn) {
      outs() << "  RPC-DRIFT    (HEADER_DRIFT_WARN_ONLY) continuing despite skew "
                "- PIN BUMP NEEDED\n";
      return 0;
    }
    outs() << "  RPC-DRIFT    PIN BUMP NEEDED (or HEADER_DRIFT_WARN_ONLY=1 to "
              "override)\n";
    return 1;
  }
  outs() << "  RPC-DRIFT    ok: alias mig wire-equivalent to pin on every stub\n";
  return 0;
}
