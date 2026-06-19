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
//   "cmp:<pred>(<op0>,<op1>)"            an icmp vs a constant: the REPLY-side
//                                        descriptor/msgid the stub expects to receive
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
// un-enumerated payload helper is still caught), mach_msg call args (#3), and the
// reply-validation expectations (icmp vs constant - the descriptors/msgids the
// stub expects back, the only wire surface mig encodes as a compare not a store).
// A reorder permutes the set -> no change.
//
// Usage: mig-wire-manifest PIN.{bc,ll} ALIAS.{bc,ll} [--warn-only]
// Exit 0 if wire-equivalent (or --warn-only); 1 on divergence.
#include "llvm/IR/Argument.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GetElementPtrTypeIterator.h"
#include "llvm/IR/GlobalValue.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instruction.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/IR/Type.h"
#include "llvm/IR/Use.h"
#include "llvm/IR/Value.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

using namespace llvm;

namespace {

// Recursion depth caps for the value-expression serialiser: the deeper cap is
// used where the wire payload itself is recomputed (store values, call args), the
// shallower one for auxiliary positions (GEP indices, memcpy lengths, icmp sides).
constexpr int kPayloadDepth = 6;
constexpr int kAuxDepth = 4;
// A 64-bit-or-narrower integer constant is printed by value; wider ones collapse
// to "big" (the exact magnitude does not affect the wire decision).
constexpr unsigned kInlineConstBits = 64;
// Cap on the number of diverging stub names listed before summarising the rest.
constexpr int kMaxReported = 20;

// Stable per-function id for a GEP root: args/allocas/globals don't move under a
// store reorder, so these ids are reorder-invariant.
class BaseNamer {
public:
  explicit BaseNamer(const DataLayout &layout) : layout(layout) {}

  auto of(const Value *val) -> std::string {
    auto found = cache.find(val);
    if (found != cache.end()) {
      return found->second;
    }
    std::string result;
    if (const auto *arg = dyn_cast<Argument>(val)) {
      result = "a" + std::to_string(arg->getArgNo());
    } else if (const auto *allocaInst = dyn_cast<AllocaInst>(val)) {
      // Key a local buffer by its allocated SIZE, not emission order, so two
      // allocas swapping declaration order (a benign mig codegen change) do not
      // diverge.  Same-size allocas collapse to one key - a swap between them is
      // then invisible, but that is benign (same-size scratch buffers).
      if (auto size = allocaInst->getAllocationSize(layout)) {
        result = "k" + std::to_string(size->getFixedValue());
      } else {
        result = "k?";
      }
    } else if (const auto *global = dyn_cast<GlobalValue>(val)) {
      result = "g:" + global->getName().str();
    } else {
      result = "?";
    }
    cache[val] = result;
    return result;
  }

private:
  const DataLayout &layout;
  std::map<const Value *, std::string> cache;
};

auto tyStr(Type *type) -> std::string {
  std::string result;
  raw_string_ostream stream(result);
  type->print(stream);
  return stream.str();
}

// Walk a GEP chain to its root pointer WITHOUT serialising indices - just the
// base.  Used where only the root identity matters (buffer detection).  A plain
// loop, no recursion.
auto gepRoot(const Value *ptr) -> const Value * {
  while (const auto *gep = dyn_cast<GEPOperator>(ptr)) {
    ptr = gep->getPointerOperand();
  }
  return ptr;
}

// The value serialiser is expressed iteratively (an explicit work stack) rather
// than recursively, so valExpr / ptrExpr / the old ptrParts collapse into ONE
// non-recursive engine.  A frame renders either a value (Mode::Val) or a
// pointer's base+offset (Mode::Ptr); Shape records how its serialised children
// assemble back into a string.
enum class Mode : std::uint8_t { Val, Ptr };
enum class Shape : std::uint8_t { Literal, Pointer, Load, Instr, PtrParts };

// A child still to be serialised: which value, at what depth, in which mode.
struct ChildSpec {
  const Value *val;
  int depth;
  Mode mode;
};

struct Frame {
  const Value *val;
  int depth;
  Mode mode;
  bool started = false;
  Shape shape = Shape::Literal;
  std::string text;              // Literal result, or the "opcode(" prefix for Instr
  const Value *root = nullptr;   // PtrParts: GEP root
  int64_t constOff = 0;          // PtrParts: folded constant byte offset
  std::vector<uint64_t> strides; // PtrParts: stride per variable-index child
  std::vector<ChildSpec> children;
  std::vector<std::string> kids; // child results, in dispatch order
};

// Mode::Ptr setup: walk the GEP chain (no recursion), folding constant indices
// into constOff and queuing each VARIABLE index as a child to serialise at
// kAuxDepth.  Matches the old ptrParts: an all-constant GEP yields just the
// integer; a runtime index contributes a "<stride>*<index-expr>" term.
void resolvePtr(Frame &frame, const DataLayout &layout) {
  frame.shape = Shape::PtrParts;
  const Value *cur = frame.val;
  while (const auto *gep = dyn_cast<GEPOperator>(cur)) {
    for (auto gepTy = gep_type_begin(gep), end = gep_type_end(gep); gepTy != end; ++gepTy) {
      Value *index = gepTy.getOperand();
      if (StructType *structTy = gepTy.getStructTypeOrNull()) {
        frame.constOff += static_cast<int64_t>(layout.getStructLayout(structTy)->getElementOffset(
            cast<ConstantInt>(index)->getZExtValue()));
      } else {
        uint64_t const stride = layout.getTypeAllocSize(gepTy.getIndexedType());
        if (const auto *constInt = dyn_cast<ConstantInt>(index)) {
          frame.constOff += static_cast<int64_t>(stride) * constInt->getSExtValue();
        } else {
          frame.strides.push_back(stride);
          frame.children.push_back({index, kAuxDepth, Mode::Val});
        }
      }
    }
    cur = gep->getPointerOperand();
  }
  frame.root = cur;
}

// Mode::Val setup: resolve the node kind in the SAME order the recursive valExpr
// used (the pointer test precedes Argument/Constant/depth, so a pointer-typed
// argument or a load-of-pointer renders as "p[...]" exactly as before).  Leaves
// fill in `text`; composite kinds queue children.
void resolveVal(Frame &frame) {
  const Value *node = frame.val;
  if (const auto *constInt = dyn_cast<ConstantInt>(node)) {
    frame.text = "c" + (constInt->getBitWidth() <= kInlineConstBits
                            ? std::to_string(constInt->getSExtValue())
                            : std::string("big"));
  } else if (isa<ConstantPointerNull>(node)) {
    frame.text = "null";
  } else if (node->getType()->isPointerTy()) {
    // A message-buffer pointer is keyed the same way a store's destination is, so
    // an offset/aliasing shift in a mach_msg buffer arg becomes visible.
    frame.shape = Shape::Pointer;
    frame.children.push_back({node, 0, Mode::Ptr});
  } else if (const auto *arg = dyn_cast<Argument>(node)) {
    frame.text = "a" + std::to_string(arg->getArgNo());
  } else if (const auto *constant = dyn_cast<Constant>(node)) {
    frame.text = "C:" + tyStr(constant->getType());
  } else if (frame.depth <= 0) {
    frame.text = "...";
  } else if (const auto *loadInst = dyn_cast<LoadInst>(node)) {
    frame.shape = Shape::Load;
    frame.children.push_back({loadInst->getPointerOperand(), 0, Mode::Ptr});
  } else if (const auto *inst = dyn_cast<Instruction>(node)) {
    frame.shape = Shape::Instr;
    frame.text = std::string(inst->getOpcodeName()) + "(";
    for (const Use &use : inst->operands()) {
      frame.children.push_back({use.get(), frame.depth - 1, Mode::Val});
    }
  } else {
    frame.text = "?";
  }
}

// Combine a frame's serialised children into its result string.
auto assemble(const Frame &frame, BaseNamer &namer) -> std::string {
  switch (frame.shape) {
  case Shape::Literal:
    return frame.text;
  case Shape::Pointer:
    return "p[" + frame.kids[0] + "]";
  case Shape::Load:
    return "ld(" + frame.kids[0] + ")";
  case Shape::Instr: {
    std::string result = frame.text;
    bool first = true;
    for (const auto &kid : frame.kids) {
      if (!first) {
        result += ",";
      }
      first = false;
      result += kid;
    }
    return result + ")";
  }
  case Shape::PtrParts: {
    std::vector<std::string> terms;
    terms.reserve(frame.kids.size());
    for (size_t i = 0; i < frame.kids.size(); ++i) {
      terms.push_back(std::to_string(frame.strides[i]) + "*" + frame.kids[i]);
    }
    std::sort(terms.begin(), terms.end());
    std::string off = std::to_string(frame.constOff);
    for (const auto &term : terms) {
      off += "+" + term;
    }
    return namer.of(frame.root) + "+" + off;
  }
  }
  return "?";
}

// The iterative driver: depth-first, but with an explicit stack.  A frame is set
// up once, then dispatches its children one at a time; each completed child's
// result is appended to its parent's kids, and a frame with all children done is
// assembled and popped.  Equivalent to the old recursive valExpr/ptrExpr.
auto serialize(const Value *startVal, const DataLayout &layout, BaseNamer &namer, int startDepth,
               Mode startMode) -> std::string {
  std::vector<Frame> stack;
  stack.push_back({startVal, startDepth, startMode});
  std::string done; // result of the most recently completed frame
  while (!stack.empty()) {
    Frame &frame = stack.back();
    if (!frame.started) {
      frame.started = true;
      if (frame.mode == Mode::Ptr) {
        resolvePtr(frame, layout);
      } else {
        resolveVal(frame);
      }
    }
    if (frame.kids.size() < frame.children.size()) {
      const ChildSpec spec = frame.children[frame.kids.size()];
      stack.push_back({spec.val, spec.depth, spec.mode});
      continue; // serialise the child, then resume this frame
    }
    const std::string result = assemble(frame, namer);
    stack.pop_back();
    if (stack.empty()) {
      done = result;
    } else {
      stack.back().kids.push_back(result);
    }
  }
  return done;
}

// Canonical, name-independent expression of a value (depth-capped), and the
// pointer base+offset form - both dispatch to the iterative engine above.
auto valExpr(const Value *val, const DataLayout &layout, BaseNamer &namer, int depth)
    -> std::string {
  return serialize(val, layout, namer, depth, Mode::Val);
}

auto ptrExpr(const Value *ptr, const DataLayout &layout, BaseNamer &namer) -> std::string {
  return serialize(ptr, layout, namer, 0, Mode::Ptr);
}

// Just the GEP-root id (no offset) - used to tell whether a pointer aims at the
// message buffer (a base that receives stores).  Needs no DataLayout: it never
// serialises offsets, only names the root.
auto baseId(const Value *ptr, BaseNamer &namer) -> std::string { return namer.of(gepRoot(ptr)); }

// Calls that carry wire marshalling.  mach_msg* is the send/recv primitive
// (sizes/options); the __mig_* helpers move the actual payload: __mig_memcpy /
// __mig_strncpy do OOL & string copies, __mig_allocate / __mig_deallocate set
// up OOL buffers.  Reply-port bookkeeping (__mig_{get,put,dealloc}_reply_port)
// and llvm.lifetime.* are local, not wire - excluded.  Note "__mig_deallocate"
// is NOT a substring of "__mig_dealloc_reply_port", so the contains() is safe.
auto isWireCall(StringRef name) -> bool {
  return name.contains("mach_msg") || name.contains("__mig_memcpy") ||
         name.contains("__mig_strncpy") || name.contains("__mig_allocate") ||
         name.contains("__mig_deallocate");
}

// Per-instruction fact builders.  Each returns the canonical fact string, or an
// empty string when the instruction contributes no wire fact (e.g. a non-wire
// call, or an icmp not against a constant).

auto storeFact(const StoreInst &store, const DataLayout &layout, BaseNamer &namer) -> std::string {
  return "st@" + ptrExpr(store.getPointerOperand(), layout, namer) + ":" +
         tyStr(store.getValueOperand()->getType()) + "=" +
         valExpr(store.getValueOperand(), layout, namer, kPayloadDepth);
}

auto memcpyFact(const MemCpyInst &copy, const DataLayout &layout, BaseNamer &namer) -> std::string {
  return "mc@" + ptrExpr(copy.getDest(), layout, namer) + "=" +
         valExpr(copy.getLength(), layout, namer, kAuxDepth) + "<-" +
         ptrExpr(copy.getSource(), layout, namer);
}

auto callFact(const CallInst &call, const DataLayout &layout, BaseNamer &namer,
              const std::set<std::string> &bufBases) -> std::string {
  const Function *callee = call.getCalledFunction();
  if (callee == nullptr) {
    return "";
  }
  StringRef const name = callee->getName();
  if (name.starts_with("llvm.")) {
    return ""; // intrinsics: effect flows via args
  }
  bool wire = isWireCall(name);
  if (!wire) {
    for (const Use &use : call.args()) {
      if (use.get()->getType()->isPointerTy() && (bufBases.count(baseId(use.get(), namer)) != 0U)) {
        wire = true;
        break;
      }
    }
  }
  if (!wire) {
    return "";
  }
  std::string result = "call:" + name.str() + "(";
  bool first = true;
  for (const Use &use : call.args()) {
    if (!first) {
      result += ",";
    }
    first = false;
    result += valExpr(use.get(), layout, namer, kPayloadDepth);
  }
  return result + ")";
}

// Reply-validation expectations: mig checks a RECEIVED descriptor / msgid by
// COMPARING it against an expected constant (icmp), not by storing it.  Capture
// {predicate, both operand exprs} whenever one side is a constant, so a reply-side
// descriptor/msgid drift - e.g. an out-only type swap, invisible to the request
// stores - is caught, symmetric to the request descriptors we get for free as
// inline stores.  Only const-compares (the "expected value" pattern);
// reorder-stable as a set.
auto icmpFact(const ICmpInst &icmp, const DataLayout &layout, BaseNamer &namer) -> std::string {
  const Value *lhs = icmp.getOperand(0);
  const Value *rhs = icmp.getOperand(1);
  if (!isa<ConstantInt>(lhs) && !isa<ConstantInt>(rhs)) {
    return "";
  }
  // Canonicalise the constant to the RIGHT (flipping the predicate to match) so
  // "icmp eq %t, C" and "icmp eq C, %t" - the same check, just operands swapped -
  // produce one fact, not a false positive.
  CmpInst::Predicate pred = icmp.getPredicate();
  if (isa<ConstantInt>(lhs) && !isa<ConstantInt>(rhs)) {
    std::swap(lhs, rhs);
    pred = icmp.getSwappedPredicate();
  }
  return "cmp:" + CmpInst::getPredicateName(pred).str() + "(" +
         valExpr(lhs, layout, namer, kAuxDepth) + "," + valExpr(rhs, layout, namer, kAuxDepth) +
         ")";
}

auto manifest(Function &func) -> std::set<std::string> {
  const DataLayout &layout = func.getParent()->getDataLayout();
  BaseNamer namer(layout);
  // Pass 1: the bases that receive stores ARE the message buffer(s).  Any later
  // call that passes a pointer into one of them is marshalling the wire, even if
  // it is not on the isWireCall allow-list - this catches an OOL/payload helper
  // we have not enumerated (a new __mig_*, a custom copy routine, ...) without a
  // name list.  Bookkeeping calls (reply-port helpers take an i32, not a buffer
  // pointer) stay out.
  std::set<std::string> bufBases;
  for (auto &inst : instructions(func)) {
    if (auto *store = dyn_cast<StoreInst>(&inst)) {
      bufBases.insert(baseId(store->getPointerOperand(), namer));
    }
  }
  std::set<std::string> facts;
  for (auto &inst : instructions(func)) {
    std::string fact;
    if (auto *store = dyn_cast<StoreInst>(&inst)) {
      fact = storeFact(*store, layout, namer);
    } else if (auto *copy = dyn_cast<MemCpyInst>(&inst)) {
      fact = memcpyFact(*copy, layout, namer);
    } else if (auto *call = dyn_cast<CallInst>(&inst)) {
      fact = callFact(*call, layout, namer, bufBases);
    } else if (auto *icmp = dyn_cast<ICmpInst>(&inst)) {
      fact = icmpFact(*icmp, layout, namer);
    }
    if (!fact.empty()) {
      facts.insert(fact);
    }
  }
  return facts;
}

auto load(const char *path, LLVMContext &ctx) -> std::unique_ptr<Module> {
  SMDiagnostic err;
  auto mod = parseIRFile(path, err, ctx);
  if (!mod) {
    err.print("mig-wire-manifest", errs());
    exit(2);
  }
  return mod;
}

} // namespace

auto main(int argc, char **argv) -> int {
  if (argc < 3) {
    errs() << "usage: mig-wire-manifest PIN ALIAS [--warn-only]\n";
    return 2;
  }
  bool warn = false;
  for (int i = 3; i < argc; i++) {
    if (std::string(argv[i]) == "--warn-only") {
      warn = true;
    }
  }

  LLVMContext ctx;
  auto pin = load(argv[1], ctx);
  auto ali = load(argv[2], ctx);

  std::map<std::string, std::set<std::string>> pinManifests;
  for (auto &func : *pin) {
    if (!func.isDeclaration()) {
      pinManifests[func.getName().str()] = manifest(func);
    }
  }

  int common = 0;
  int diverge = 0;
  std::set<std::string> diffNames;
  for (auto &func : *ali) {
    if (func.isDeclaration()) {
      continue;
    }
    auto found = pinManifests.find(func.getName().str());
    if (found == pinManifests.end()) {
      continue;
    }
    common++;
    if (found->second != manifest(func)) {
      diverge++;
      diffNames.insert(func.getName().str());
    }
  }

  outs() << "  RPC-DRIFT    wire-fact manifest: " << diverge << "/" << common
         << " stub functions diverge in the alias build\n";
  int shown = 0;
  for (const auto &name : diffNames) {
    if (shown++ >= kMaxReported) {
      break;
    }
    outs() << "    ! " << name << "\n";
  }
  if (static_cast<int>(diffNames.size()) > kMaxReported) {
    outs() << "    ... and " << (diffNames.size() - kMaxReported) << " more\n";
  }

  if (diverge != 0) {
    if (warn) {
      outs() << "  RPC-DRIFT    (HEADER_DRIFT_WARN_ONLY) continuing despite skew "
                "- PIN BUMP NEEDED\n";
      return 0;
    }
    outs() << "  RPC-DRIFT    PIN BUMP NEEDED (or HEADER_DRIFT_WARN_ONLY=1 to "
              "override)\n";
    return 1;
  }
  outs() << "  RPC-DRIFT    ok: alias build wire-equivalent to pin on every stub\n";
  return 0;
}
