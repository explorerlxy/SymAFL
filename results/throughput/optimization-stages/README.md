# P1/P2/P3 Incremental Optimization Experiments

Date: 2026-07-28

Staged implementation of the engineering proposals from
[symbolic-cost-breakdown](../symbolic-cost-breakdown/README.md), with an
incremental comparison experiment after each stage.

| Stage | Change | Component commit |
|---|---|---|
| P0 | Baseline (SymAFL-v1, `ae69532`) | — |
| P1 | `addIfUnique` dedup: SMT string → Z3 AST id | symcc `a24df13` |
| P2 | Eager simplify-on-materialize → opt-in (`SYMCC_SIMPLIFY_ON_MATERIALIZE`) | symcc `293cacf` |
| P3 | Lazy constraint trace (no Z3 at trace time) + AFL-gated `.pct` dump via replay of gaining candidates; InsertTrace scalability fixes | symcc `4d4673d`, AFLplusplus `82ea8839` |

## Standalone concolic execution (valid seed, wall time, best of 3)

| Target | P0 | P1 | P2 | P3 | Speedup |
|---|---:|---:|---:|---:|---:|
| XZ/liblzma | 3.50 s | 0.49 s | 0.13 s | **0.09 s** | **39×** |
| libxml2 | 0.064 s | 0.03 s | 0.03 s | **0.02 s** | ~3× |

## Target-side Z3 work per concolic execution (XZ valid seed, shim)

| Metric | P0 | P1 | P2 | P3 |
|---|---:|---:|---:|---:|
| Total Z3 calls | 1,319,952 | 1,330,295 | 576,215 | **21** |
| `Z3_ast_to_string` | 10,343 (2,898 ms) | 0 | 0 | 0 |
| `Z3_simplify_ex` | 55,658 (339 ms) | 55,658 (307 ms) | 0 | 0 |
| Trace-time Z3 | all of it | simplify only | AST ctor+assert | **none** (init only) |

Raw shim outputs: `xz-p{1,2,3}-shim.txt`, `xml-p{1,2,3}-shim.txt`
(P0: `../symbolic-cost-breakdown/`).

## AFL `-K` integration runs (libxml2, `-t 2000`)

| Metric (30 s runs) | P0 diag | P1 | P2 | P3 (no-insert run) |
|---|---:|---:|---:|---:|
| Candidates | 1,063 | 1,474 | 1,792 | **5,027** |
| Concolic exec/s | 36.2 | 54.9 | 70.8 | **166.5** |
| Corpus found | 62 | 83 | 81 | 179 |
| Trace insertions | 2 | 2 | 2 | 2 (all gains `var_behavior`-blocked) |

P3 as first deployed replayed gaining candidates and inserted their traces —
which the previous `var_behavior` guard had silently blocked for **every**
admission. Enabling learning exposed three latent fuzzer-side stalls, fixed
in the same commit:

1. **graphviz PNG rendering on every insertion** (11–18 s each via `system("dot …")`) — now gated behind `AFL_PCBT_RENDER`, snapshots every 32 insertions.
2. **Eager per-node Z3 solver construction** in `PathConNode::init()` — now lazy (built on first `check()`).
3. **Combinatorial DAG re-traversal** in the sym-var walk — now memoized by AST id.

After the fixes (60 s runs, learning enabled):

| Metric | libxml2 P3 | xz P3 |
|---|---:|---:|
| Candidates | 2,672 (44.5/s) | 99 |
| Concolic exec/s | 145.0 | 6.14 (P0: 1.87) |
| Trace insertions | **147** | **43** (P0: 1) |
| Replay / mismatch | 146 / 1 | 46 / 4 |
| Corpus found | 146 | 46 |
| CheckInput/s | 218 | 2.78 |

Notes:

- libxml2 candidate throughput with learning (44.5/s) is below the
  no-learning P3 run (168/s) and slightly below P2 (59.7/s): growing trees
  make CheckInput progressively more expensive. This is the expected cost of
  actually maintaining the PCBT — P0–P2 never learned anything beyond the
  dry-run seeds (all 2 insertions), so their throughput figures describe a
  screening-only regime with a frozen tree.
- xz previously hung the fuzzer (50 GB RSS, graphviz + eager solvers); it now
  completes runs and learns. Its remaining bottleneck is fuzzer-side
  CheckInput (2.78/s ≈ 360 ms/candidate) over the large valid-seed tree —
  the known PCBT scalability issue, now precisely isolated.
- Replay mismatches (1 libxml2, 4 xz) are executions whose concolic paths are
  not reproducible; their queue entries are kept but traces discarded. xz's
  higher mismatch count is consistent with its `expr.h:443` FATAL truncating
  runs (P6, still open).

## .pct equivalence (P2 vs P3, same dry-run seed)

Line counts 350 vs 352; content semantically equivalent. Textual differences
come from P3 bypassing `solver.add` (no Z3 solver-side preprocessing/aux
naming) — constraints are dumped as directly materialized. Both forms parse
and drive screening successfully.

## Where the remaining cost is

- Target-side concolic tracing is now pure qsym bookkeeping (XZ: 10,397
  branch constraints cost 15 ms total, 1.5 µs each).
- The new bottleneck is **fuzzer-side**: `CheckInput` Z3 solving grows with
  tree size (libxml2 4.6 ms/candidate; xz 360 ms/candidate), and each
  admitted candidate still pays the concolic execution. Further work:
  memoized/prefix-cached CheckInput descents, solver-result caching for
  sibling mutations in deterministic stages, and the P6 XZ bit-width FATAL.

## Verification per stage

Each stage ran: standalone unshimmed timing ×3 (both targets), shimmed
profile, simpletest end-to-end (`.pct` artifacts + counters), and 30–60 s
AFL `-K` runs. Final P3 verification: simpletest (replay 1, insert 2,
exhaustion), libxml2 60 s, xz 60 s. AFL outputs: `libxml2-p1/`, `libxml2-p2/`,
`libxml2-p3/` (from the `libxml2-p3e` run), `xz-p3/`.
