# From First Principles: Symbolic Tracking & Path-Constraint Encoding from Zero

Date: 2026-07-28
Status: design exploration (path-dependency-free redesign; relationship: v2's
consumer side is confirmed, v2/v3 producer becomes a pluggable tier)
Question: if we discard SymCC/SymSan/v2 lineage entirely and design testcase
symbolic tracking + path-constraint expression encoding from scratch, what
should it be?

## 1. The first-principles derivation

### 1.1 What the consumer actually needs

PCBT-guided screening consumes exactly three things per execution:

1. an **ordered branch-event sequence** `(site, taken, predicate)` from
   `insert_depth` onward;
2. predicates as **closed boolean functions of the input byte string** —
   evaluated natively, never solved;
3. per-predicate **input-byte dependence sets** (symVars) for prefix
   invalidation and diff pre-filtering.

Plus, on crash: the record prefix up to the RSan `int3` (vuln→path binding).

### 1.2 The load observation

A branch predicate is a *pure function of the input bytes*. Execution is
merely an expensive way to compute that function's representation. So the
design question is not "how do we track symbols fast" but:

> **What is the minimum work per execution that yields, for each branch, a
> compact evaluable representation of its condition as a function of input
> bytes — and how rarely must that work happen at all?**

### 1.3 The frequency hierarchy

The PCBT contract imposes a three-level frequency structure, and cost should
be allocated by level:

| Level | Trigger | Frequency (measured) | Budget |
|---|---|---|---|
| Screening | every candidate | ~10^3–10^4/s | µs, **no execution** |
| Admitted execution | CheckInput admit | ~10–50% of candidates | one fast concrete-class run |
| Symbolization | coverage gain or crash | 5–40% of admitted (7% on libxml2) | heavy machinery allowed |

v1 data: libxml2 938 admitted → 873 no-gain (93%). **Expression building for
no-gain runs is waste by construction** — any design that builds expressions
during the common run pays its largest cost for output that is discarded.

### 1.4 The information-theoretic minimum

A predicate instance is fully determined by:

- the **static backward slice** of the branch condition (compile-time, free,
  computed once per build);
- **taint bits**: which slice values are input-derived in *this* execution
  (1 bit per value);
- **boundary concrete values**: the values of maximal untainted subtrees
  (fold to constant leaves);
- **input-offset provenance**: which load sites read which input offsets
  (mostly static per site; dynamic only for data-dependent addressing).

Key corollary: **untainted instructions never need to be recorded** — an
untainted operand is a constant leaf equal to its concrete value. The dynamic
record only needs to cover the *tainted cone*: instructions with at least
one tainted operand.

## 2. The three-tier architecture

```
candidate ──► T1: CheckInput (native eval, fuzzer-side)        [every candidate]
                │ admit
                ▼
   T2: FAST binary = RSan + AFL coverage, ZERO symbolic        [per admitted]
       machinery; jobs: coverage feedback, RSan crash detect
                │ gain / crash (rare)
                ▼
   T3: SYMBOLIC PRODUCER run → predicates from insert_depth    [per gain/crash]
       → intern into arena → InsertTrace → enqueue
```

- **T1** is the v2 consumer stack unchanged (VM → prefix cache → JIT).
- **T2** is a separately built binary *without* the SymCC pass. Measured
  motivation: the full SymAFL binary's concrete mode is 13–32× slower than a
  SymCC-free build (RSan + scaffolding); the common run should pay neither.
  Determinism between builds is required and is the main engineering caveat
  (same input → same path; coverage edge IDs must be build-consistent, or
  T2/T3 use one binary with the runtime mode switch, paying scaffolding in
  T2 — a measurable trade-off, not a correctness question).
- **T3** is the *only* place symbolic tracking exists. Because it runs on
  gain/crash only, its engine choice is an optimization, not a bottleneck.
  Note this is the generalization of the P3 lazy-trace/replay pattern
  already validated in v1: no-gain = cheap run; gain = replay with dumping.

**The headline principle: the best tracking optimization is making tracking
rare.** Eager engines (SymCC, SymSan) optimize the per-op cost of work that
is 60–93% discarded; the from-scratch design gates the work itself.

## 3. The T3 producer spectrum

T3 needs, per replayed execution, the branch-event sequence with predicate
DAGs. Producer options, ordered by how much structure is carried forward
during the run:

### 3a. Eager per-op expression building (status quo producer)
SymCC/SymSan-style: build the DAG for every tainted value as computed;
serialize branch conditions at the end. Trivially correct; pays full
expression cost for the whole run. Adequate because T3 is rare; already
built and fixed (P1–P6).

### 3b. Slice-restricted eager
Compile-time: compute the union of backward slices of all conditional-branch
conditions; instrument expression building only for slice members. Static
over-approximation (in parsers the union covers most code) but skips
provably non-cone computation. No reconstruction machinery; predicates
immediately available.

### 3c. Lazy: taint + minimal op trace + fuzzer-side cone reconstruction (the principled end point)
During the run:
- **boolean taint** propagation (DFSan-style, direct-mapped shadow), every
  shadow cell extended with a **last-writer trace index** (registers via
  compile-time shadow variables, memory via shadow cells);
- per **tainted instruction**, append a compact record to the SHM stream:
  `{site_id, operand producer indices (from shadows), concrete output value,
  load-address (for input-range leaf detection)}` — ~12–20 B, sequential
  append, no calls, no hashing, no dedup;
- per **branch event**, append `{site_id, taken, condition producer index}`;
- input loads become `(offset, len)` leaves via concrete address − input
  base (uload fusion for free).

After the run (fuzzer-side, only on gain/crash): backward DFS from each
branch condition's producer index over the record stream; untainted operand
→ constant leaf from its recorded concrete value; emit post-order nodes
directly into the interned arena. **Work ∝ output cone size — information-
theoretically optimal.** No-gain runs (the majority) never pay it.

Memory versioning folds into the shadow (last-writer index), so store-to-
load links are exact; SSA discipline makes register links exact; threads are
out of scope (as today).

### 3d. Hardware-trace replay (rejected)
Intel PT + offline reconstruction: lowest in-run cost (~1–5%) but requires
deterministic re-execution for data values, a PT decoder, and ASLR/rdtsc/
signal hygiene. Heavy engineering for a tier that is already rare. Rejected.

### Recommendation
Ship T3 with **3a** (exists, correct, rare). Evaluate **3c** as v3 only if
T3 replays become measurable in the throughput denominator. 3b is a fallback
if reconstruction correctness (3c's real risk surface: memory versioning,
taint-loss, interprocedural edges) proves harder than projected.

## 4. The encoding (designed for its access pattern)

Access pattern: **write once, evaluate against thousands of candidates,
shared heavily across executions and predicates**. So: layout = evaluation
bytecode; identity = interning.

```c
// arena node, 16 B, append-only, offsets not pointers
struct PNode {
  u8  op;        // BV ISA: read/const/add/.../shl/ult/eq/concat/extract/zext/sext/ite
  u8  flags;     // c1_is_const, c2_is_const, opaque, ...
  u16 bits;      // result width
  u32 c1, c2;    // arena-relative node index, or leaf descriptor
  u64 aux;       // inline constant (≤64b) / input leaf (offset:32, len:16)
};
// parallel array: u64 merkle_hash[] — per-node structural hash
```

- **Post-order per predicate**; a predicate *is* its root index. The
  serialization is the VM bytecode — zero transform at consumption.
- **Global interning** (Merkle hash → index, open addressing): structural
  sharing across runs and predicates; O(1) predicate equality; arena size
  bounded by unique structure, not by inserted traces. Adopted from SymSan
  (hash-first identity check), validated there.
- **Fused input leaves** `(offset, len)` — SymSan's `uload` (measured
  13.8:1 vs concat); cancels per-byte shadow concat bloat at the source.
- **symVars as sorted (offset, len) ranges**, computed during
  reconstruction; feeds prefix invalidation and the `diff ∩ symVars = ∅`
  O(1) pre-reject.
- **Emergent property**: interning + post-order ⇒ per-candidate **value
  memoization across predicates** — a shared sub-DAG is evaluated once per
  candidate, so evaluation cost scales with the *changed region* of the DAG
  forest, not its size. This is the encoding paying for itself beyond
  storage.
- Unsupported sorts (fp/vector/uninstrumented calls) → `opaque` flag;
  screening treats the node conservatively (admit-without-counting), never
  silently prunes. Taint loss is therefore a *documented best-effort*
  degradation, same class as every existing engine's uninstrumented-code
  behavior.
- ABI version in the arena header (ties into `compatibility.yaml`).

## 5. Risk register

| Risk | Tier | Mitigation |
|---|---|---|
| T2/T3 build determinism (two binaries) | T2/T3 | fixed-seed coverage map; fallback: one binary + `*__symbolic` mode switch (pay scaffolding in T2) |
| Replay path mismatch on gain | T3 | v1 contract already gates InsertTrace on replay-bitmap equality |
| Memory-versioning bugs in lazy reconstruction | 3c | shadow last-writer invariants; differential test vs eager producer on same seeds (verdict equality) |
| Taint loss (wrappers, asm, uninstrumented libs) | 3c | opaque nodes; wrapper family for read/memcpy/memcmp (fmemcmp later) |
| Trace overflow on extreme runs | 3c | flag → run uninsertable (same semantics as today's `.pct` overflow) |
| Slice unsoundness (if 3b used) | 3b | over-approximate; treat gaps as opaque |

## 6. Relationship to the current roadmap

The from-scratch exercise **converges back onto the v2 consumer side in
full** (arena, post-order encoding, VM/cache/JIT, gain-gated retention) —
that is a strong correctness signal for v2. What it changes is the framing
of the producer:

- v2 (as designed): eager producer, serialize-ready DAGs — keep, it is the
  low-risk producer for T3 and validates the entire consumer stack.
- The three-tier split says: pursue **T2 binary slimming** (RSan+AFL-only
  build for admitted runs) before touching the producer — it targets the
  13–32× concrete overhead, a larger term than the 1–6% tracking.
- v3 = lazy producer (3c) if and only if T3 replays show up in measurements.

Effort allocation follows the frequency hierarchy: T1 (every candidate) →
T2 (every admitted) → T3 (every gain). Never optimize a lower tier first.
