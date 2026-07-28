# TRACE_RECORDER_V2 — SHM Binary Trace for PCBT Construction

Date: 2026-07-28
Status: design proposal (v2 architecture; drops target-side Z3 entirely)

## Motivation

The fuzzer-side PCBT only needs the **incremental path-constraint sequence**
of an admitted execution. The current pipeline carries the full baggage of a
solver-oriented concolic engine: target-side Z3 context/solver, per-branch
`to_string()` dedup (82.7% of XZ concolic CPU), eager simplify (9.7%),
SMT-LIB serialization to `.pct` on disk, and fuzzer-side SMT re-parsing.
Measured symbolic *tracking* (DAG build + shadow memory + notify) is only
1–6% of concolic CPU. v2 keeps the cheap part and deletes the rest.

## Minimal contract (what the fuzzer actually needs per admitted run)

1. Ordered branch records `(site_id, taken, condition-DAG)` — only from
   `insert_depth` onward;
2. Coverage feedback (already have: AFL bitmap);
3. Crash point (record prefix up to RSan `int3`, for vuln→path binding).

Not needed target-side: Z3 solver, constraint dedup, simplify, SMT text,
`.pct` files, exit-time serialization, fuzzer-side SMT parsing.

## Architecture

```
Symbolizer pass (keep)     QSYM DAG builder (keep, 1–6% cost)
        │                          │
        ▼                          ▼
  branch event ──► TraceRecorder ──► SHM ring buffer ──► AFL++ PathConTree
                  (new ~300 LoC)   (6th SHM channel)     direct z3::expr /
                                                           native eval
                                                           (~200 LoC)
```

### Record format (self-contained, execution order)

```c
struct BranchRec {          // written only when branch_ordinal >= insert_depth
  u32 site_id; u8 taken; u8 flags; u16 node_count;
  Node nodes[node_count];   // post-order serialization of the condition DAG
};
struct Node {               // ~16 B
  u8  opcode;               // add/xor/eq/ult/concat/extract/ite/read/const/...
  u8  kind;                 // const / input-byte / operator
  u16 bits;
  i32 child1, child2;       // indices within this record; -1 = leaf
  u64 aux;                  // constant value or input-byte offset
};
```

### Protocol

- AFL writes `__symbolic` and `__insert_depth` before the fork as today;
  the runtime only counts branch ordinals and **serializes nothing for
  ordinals < insert_depth** — the entire path prefix is skipped for free.
- Condition DAGs are memoized by pointer identity per record (same `ExprRef`
  → same node index). Loop iterations hitting the same
  `(site, taken, expr_ptr)` are skipped by a small pointer-keyed set —
  replacing the current string-rendering dedup (the 83% item).
- The child does **nothing at exit**: SHM belongs to the AFL parent; records
  are already in fuzzer hands after `waitpid`. No-gain executions therefore
  cost **tracking only** — the common PCBT case. On crash, the record prefix
  is already in the ring; the fuzzer may serialize `.pct` itself offline if
  triage needs it.
- No target-side Z3 at all (no context/solver/simplify/to_string);
  CallStackManager, GC, `solver.add`, and the dedup set are removed.
- Ring sizing: prefix serialization is skipped, so records cover only the
  suffix from `insert_depth`; a few MB suffice. Overflow sets a flag; AFL
  treats the trace as failed insertion (same handling as today's missing
  `.pct`).
- PathConTree rebuilds expressions from the opcode table (into its existing
  `z3::context`, or directly into the Stage-1 evaluation VM of
  [CHECKINPUT_COMPILED_EVAL](CHECKINPUT_COMPILED_EVAL.md) — no Z3 either
  way). `CheckInput`/`InsertTrace`/rCnt logic unchanged.

## Keep vs delete

| Keep (measured cheap) | Delete (measured dominant or unused) |
|---|---|
| Symbolizer pass instrumentation | All target-side Z3 (context/solver/simplify/to_string) |
| QSYM DAG builder + hash-cons | `addIfUnique` string dedup (82.7%) |
| Shadow memory (page map) | Eager simplify-on-materialize (9.7%) |
| forkserver + coverage instrumentation | `save_solver_to_file` + `.pct` + SMT re-parse |
| `insert_depth` semantics | CallStackManager/XXH32, GC, `solver.add` |

## Expected effect (from the cost breakdown)

| Target | Current concolic | After recorder | Basis |
|---|---:|---:|---|
| libxml2 | 47–64 ms | ≈ concrete +5–25% | tracking alone ≈ 0.5 ms |
| XZ deep path | 3,594 ms | ~200–350 ms | −83% to_string, −10% simplify |
| No-gain executions | full price | tracking only (~0.5 ms xml) | zero serialization |

## Rollout

1. P1+P2+P4 (~35 LoC): `addIfUnique` → `Z3_get_ast_id`, env-gated simplify,
   CallStackManager no-op without linearization. No protocol change;
   validates the cost model on xz/libxml2. (Done 2026-07-28, see
   `results/throughput/optimization-stages/`.)
2. Recorder (~500–600 LoC): 6th SHM channel, `compatibility.yaml` →
   `symafl-abi-v2`; `.pct` becomes an optional fuzzer-side debug artifact.
3. Pair with Stage-1 VM in CHECKINPUT_COMPILED_EVAL.md for a fully
   solver-free hot path.
