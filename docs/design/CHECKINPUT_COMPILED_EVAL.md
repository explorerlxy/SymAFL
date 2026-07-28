# CheckInput as Compiled Native Evaluation (Solver-Free Screening)

Date: 2026-07-28
Status: design proposal (responding to the "incrementally compiled predicate
function" idea; concludes: feasible and recommended, staged VM-first)

## Core observation

`CheckInput(candidate)` asks, at each PCBT node:

> Does THIS concrete byte sequence satisfy THIS branch predicate?

All free variables in a node predicate are input bytes; the candidate binds
them all. That is **expression evaluation**, not satisfiability search. The
current implementation routes it through a full Z3 solver (`solver.push` +
per-byte equality assertions + `check()`), paying solver setup, assertion
management, and decision-procedure overhead for what is straight-line
bit-vector arithmetic.

No place in the v1 screening loop needs existential reasoning:

- admitting a candidate = the candidate evaluates to an unexplored child;
- low-value (rCnt) counting = pure counting;
- InsertTrace = data ingestion.
  (Whether an unexplored right branch is satisfiable *at all* is learned by
  executing admitted candidates, exactly as today — unchanged semantics.)

Consequence: the entire fuzzer-side hot path can drop Z3, matching the
TRACE_RECORDER_V2 design in which the target side drops Z3 as well.

## Staged design

### Stage 0 — DAG interpreter over `z3::expr` (works today, no protocol change)

Replace `PathConNode::check()`'s solver call with a post-order walker over
the existing z3 AST. ~150–200 LoC in `PathConTree.cpp`. Validates the cost
model before any protocol work and gives the win immediately after P2 (which
made constraints unsimplified/bigger — solver cost grew, evaluation cost per
node stays linear).

### Stage 1 — bytecode VM over the recorder's binary DAG (target design)

The recorder's `BranchRec.nodes[]` is already a post-order serialization —
i.e., bytecode. Per node store:

```cpp
struct Ins { u8 op; u16 bits; i32 a, b; u64 imm; };   // 16 B
struct CompiledNode {
    std::vector<Ins> code;      // post-order, root last
    std::vector<u32> symVars;   // input-byte offsets touched (for prefix cache)
};
```

Evaluation = one linear pass with a value array (`__uint128_t` lanes,
per-ins width masks). Cost per candidate ≈ Σ predicate sizes along the path
× ~1–3 ns/op — microseconds where Z3 costs milliseconds.

### Stage 2 — prefix-invalidation cache (bigger structural win than JIT)

AFL mutants differ from their parent in a few bytes. Cache per parent the
per-node verdicts; a verdict prefix remains valid up to the first node whose
`symVars` intersect the mutated byte range (length changes invalidate all —
splice). Re-evaluate only the suffix. On deep trees (XZ) this is the
difference between O(path) and O(changed region) per candidate — the expected
order-of-magnitude term, and it works for both Stage 0 and Stage 1.

### Stage 3 — whole-tree JIT with hot-patching (user's formulation, refined)

One machine-code function isomorphic to the PCBT: args are
`(const uint8_t *input, uint32_t len)`, body is an if-else chain mirroring
the tree. Each tree node is a stable-address block:

```
block(N):  eval pred(N) into a flags/condition register
           jtrue  <left block or REJECT leaf>
           jmp    <right block or frontier stub>
```

Unexplored frontier = a 6-byte stub `mov eax, node_id ; ret`
(`B8 imm32 C3`), which is ≥ the 5-byte `jmp rel32` needed to patch it.
Admission returns the admitting node's id (0 = reject, −2 = exhausted
root), giving the C++ side everything needed for `insert_depth` and `rCnt`
bookkeeping.

**Incremental update is monotonic hot-patching** — only three patch types
ever occur, each at most once per site:

1. **Frontier extension** (InsertTrace): emit the new constraint chain as
   blocks (each new node = one eval block + one fresh frontier stub), then
   patch the frontier stub into `jmp rel32` to the new chain head
   (emit-before-patch publish; x86 cross-modifying code is self-coherent;
   the fuzzer is single-threaded).
2. **Low-value saturation** (rCnt threshold): patch the opportunity branch
   to a shared `return REJECT` stub.
3. **Subtree exhaustion** (expCnt cascade): patch the exhausted subtree's
   entry to `return REJECT`; when the root saturates, patch the function
   entry to `return −2`.

Code lives in an append-only arena (RWX, or a dual-mapped RW/RX pair if
W^X hygiene is desired); block addresses are stable for the campaign, which
also keeps the Stage-2 prefix cache compatible: `CheckInput` may enter the
function at any mid-tree node block, not just the root.

**Risk split.** Tree-dispatch code (branches, stubs, patches) is trivially
correct; the real correctness surface is native emission of predicate
semantics (BV corner cases from the checklist). Mitigation is layered
degradation: tree dispatch is JIT'd first while predicates call the Stage-1
VM; full native predicate emission comes last, and any node with an
unsupported opcode falls back to the VM (or is marked `opaque`). The C++
tree remains the authoritative metadata (symVars, rCnt, expCnt, ids); the
machine code is a derived accelerator that can be discarded and rebuilt.

**Economics.** Root-prefix nodes are walked by every candidate, so per-node
compile cost amortizes over thousands of screenings; the expected speedup
over the VM is dispatch/branch-predictor locality (≈10–30%), while the
dominant terms remain solver removal (100–1000×) and the prefix cache
(10–100× on deep trees). JIT is polish, not the main term — but the
patch-based design makes it incremental and cheap.

## Semantics that MUST be preserved (SMT-LIB bit-vector corner cases)

- `bvudiv x 0 = 2^w − 1`; `bvurem x 0 = x`; `bvsdiv x 0 = (x<0 ? 1 : −1)`;
  `bvsrem x 0 = x`; `bvsmod x 0 = x` — native division traps, so these need
  explicit branches.
- `bvshl/bvlshr/bvashr` with shift amount ≥ width → 0 (C/C++ is UB); `bvashr`
  sign-fills.
- Exact-width semantics: mask after every op (`val & ((1<<bits)−1)`); signed
  comparisons via sign-extension to the evaluation lane width.
- `concat/extract/zero_extend/sign_extend` are pure bit plumbing.
- Bytes beyond candidate length: keep the current rule (`sv >= size → node
  verdict false`), identical to today's conservative behavior.
- Floating point and non-BV sorts: fall back to Z3 for that node (keep
  libz3 linked for the rare path and for `.pct` export/debug).

## Expected effect (anchored to measurements)

- libxml2 CheckInput 4.6 ms/candidate → µs level (≈ 2–3 orders of magnitude).
- XZ 2.78 candidates/s (large tree) → prefix cache makes typical candidates
  re-evaluate only the mutated suffix; expected 10–100× on top of the VM.
- Together with TRACE_RECORDER_V2 (binary DAG over SHM), the v2 hot path is
  solver-free end-to-end: target does DAG tracking, fuzzer does native
  evaluation; Z3 remains only as an offline `.pct`/debug verifier.

## Effort estimate

| Stage | LoC | Time | Risk |
|---|---:|---|---|
| 0: z3-AST interpreter | ~200 | 0.5 day | low (semantics checklist above) |
| 1: binary-DAG VM + InsertTrace ingestion | ~300 (+ recorder) | with recorder | low–medium |
| 2: prefix-invalidation cache | ~150 | 0.5 day | medium (length-change invalidation) |
| 3: JIT hot predicates | ~1–2k or asmjit dep | days | medium (width>64, W^X) |
