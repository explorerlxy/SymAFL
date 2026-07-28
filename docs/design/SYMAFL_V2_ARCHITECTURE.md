# SymAFL v2 Architecture — From First Principles

Date: 2026-07-28
Status: design (converges TRACE_RECORDER_V2 + CHECKINPUT_COMPILED_EVAL)

## First-principles decomposition

Strip the system down to what is logically required for PCBT-guided
screening. Only two irreducible computations exist:

1. **Provenance**: for each executed value, which input bytes (through which
   operations) produced it — symbolic propagation. Needed exactly so that a
   branch condition can be written as a predicate over input bytes.
2. **Evaluation**: for each candidate byte string, does it satisfy a stored
   branch predicate — a closed bit-vector computation. Needed exactly so the
   fuzzer can predict which branch a candidate will take.

Everything else in v1 — Z3 solver/context, SMT-LIB text, `.pct` on disk,
fuzzer-side SMT parsing, per-branch string dedup, eager simplification — is
representation overhead on top of these two computations. Measurements (see
`results/throughput/symbolic-cost-breakdown/`): provenance tracking costs
1–6% of concolic CPU; the representation layer costs the other ~95%.

## Subsystem 1 — Path-constraint sequence collection

Goal: deliver, per admitted execution, an ordered sequence
`(site, taken, predicate)` over input bytes, encoded **for the consumer**.

- **Symbolic propagation tracking** (keep; this is the irreducible cost):
  the Symbolizer pass propagates `ExprRef` DAGs through computation;
  conditional branches whose condition is non-concrete emit one record.
  DAG nodes are hash-consed by construction (shared structure, pointer
  identity = structural identity).
- **Efficient encoding** (replaces SMT-LIB):
  - one **node table per execution**, deduplicated across ALL branch records
    of the run via pointer identity (loop iterations, shared subexpressions —
    zero rendering cost, replacing the 82.7% `to_string()` dedup);
  - leaves are `(input_byte_offset, width)` or inline constants;
  - nodes are width-tagged opcodes in **post-order** — the encoding *is* the
    evaluation bytecode for Subsystem 2, so the fuzzer performs zero
    transformation;
  - emission gated by `insert_depth`: branch ordinals below it are counted
    but never serialized (the entire shared prefix is skipped);
  - transport: SHM ring buffer (6th channel); nothing happens at child exit —
    records are already in fuzzer hands. No-gain runs cost tracking only.
- Target-side Z3: **none**. No context, solver, simplify, to_string, GC,
  CallStackManager.

## Subsystem 2 — PCBT construction and checking

The tree logic of v1 (binary tree, left = taken/true, right =
untaken/opportunity, insertion depth, `rCnt` low-value pruning, `expCnt`
exhaustion) is data-structure-only and ports unchanged. What changes is the
node payload:

```cpp
struct NodeV2 {
    BytecodeView pred;      // slice into the execution node table (VM-ready)
    uint32_t    symVars;    // bitmap of input bytes the predicate reads
    NodeV2     *left, *right;
    uint16_t    rCnt;  uint8_t expCnt;
    // No z3::expr, no z3::solver, no SMT text anywhere.
};
```

- **CheckInput** = walk from root; at each node evaluate `pred(candidate)`
  natively (Stage 1 VM now; optional JIT for hot nodes later — see
  `CHECKINPUT_COMPILED_EVAL.md`). Outcomes identical to v1: first unexplored
  child → admit with that depth; exhausted root → −2; otherwise reject.
- **"JIT function consistent with the tree logic"** (user's formulation):
  implemented node-granular, not monolithic. A whole-tree recompiled function
  loses per-node caching (prefix reuse across sibling candidates) and pays
  recompilation churn on every insert. Per-node compiled predicates + a tree
  dispatcher give the same native-code speed with incremental updates:
  maintenance on insert = append bytecode (VM) / compile just the new nodes
  (JIT tier).
- **Prefix-invalidation cache** (Stage 2, the large algorithmic term):
  candidates are few-byte mutations of a parent; verdicts of nodes whose
  `symVars` avoid the mutated range are reused, so only the affected path
  suffix is re-evaluated. Length-changing splices invalidate conservatively.

## The maintenance loop (post-screening execution)

```
admitted candidate executes (symbolic mode)
  ├─ coverage gain?
  │    ├─ yes → ingest records from insert_depth (shared node table)
  │    │        → append nodes to PCBT (left = observed direction;
  │    │          last node opens the right/unexplored opportunity)
  │    │        → update CheckInput artifacts: append bytecode slices
  │    │          (VM) or compile the new nodes only (JIT tier)
  │    │        → enqueue seed → next round
  │    └─ no  → rCnt++ on the admitting node; propagate expCnt on
  │             saturation; nothing else is written anywhere
  └─ crash (RSan int3) → record prefix already in SHM; fuzzer may render
        .pct offline for triage (vuln→path binding preserved)
```

## Semantics invariants (must not drift from v1)

- Admission/rejection/exhaustion decisions identical (validated by
  differential testing: same traces + candidates through Z3-check and
  native-eval, require identical verdicts).
- BV corner cases per the checklist (div-by-zero defined values, shifts ≥
  width → 0, per-op width masks, sign extension for signed comparisons,
  `sv >= size → false`).
- Opaque payloads (float / non-BV / unimplemented opcode): node flagged
  `opaque`, verdict = admit-without-counting (never silently prunes) or a Z3
  fallback if linked. Choice recorded in `compatibility.yaml` (abi-v2).
- Optional offline audit: a background Z3 feasibility check for unexplored
  right branches may prune infeasible branches later — explicitly OFF the
  hot path, keeping "no solver in the loop" true.

## What this buys (anchored to measurements)

- Target side: concolic cost ≈ provenance tracking only (XZ deep path
  3,594 ms → ~200–350 ms; libxml2 ≈ concrete +5–25%; no-gain runs ~0.5 ms).
- Fuzzer side: CheckInput from 4.6 ms/candidate (libxml2) and 2.78 cand/s
  (XZ deep tree) to µs-level per candidate, ×10–100 more from the prefix
  cache on deep trees.
- The paper narrative simplifies to: **solver-free hybrid fuzzing** —
  symbolic propagation for learning, native evaluation for screening; a
  solver exists only as an optional offline auditor.

## Rollout

- M1 (0.5 d): Stage-0 z3-AST interpreter replacing `checkSolver.check()` +
  differential tests (BV corner-case suite). Validates eval semantics and
  measures the win with zero protocol change.
- M2 (1–2 d): TraceRecorder + NodeV2 VM (abi-v2), delete `.pct`/SMT from the
  hot path.
- M3 (0.5 d): prefix-invalidation cache.
- M4 (optional): JIT for hot predicates; offline Z3 feasibility auditor.
- Validation: six-target suite; compare candidate throughput, rejection rate,
  learned-tree size, and verdict equality against v1 semantics.
