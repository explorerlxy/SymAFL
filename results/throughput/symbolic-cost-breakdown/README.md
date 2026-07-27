# Concolic Cost Breakdown: Where SymCC/QSYM Time Actually Goes

Date: 2026-07-27

This experiment answers: **why is concolic (symbolic-tracking-only, no
constraint solving) execution so expensive, and is that cost inherent?**

Short answer: **no, it is not inherent.** Measured dynamic cost of the actual
symbolic tracking (expression DAG construction, shadow memory, notifications)
is only **~1–6%** of concolic CPU time. The rest is dominated by two removable
engineering artifacts in the vendored QSYM runtime:

1. **Per-branch `z3::expr::to_string()` dedup** in `Solver::addIfUnique()`
   (`symcc/runtime/src/backends/qsym/qsym/qsym/pintool/solver.cpp:119-124`):
   every symbolic conditional branch renders its whole constraint to an
   SMT-LIB string just to test set membership. **82.7% of XZ concolic CPU.**
2. **Eager Z3 materialization + simplify** in `Expr::toZ3Expr()`
   (`.../pintool/expr.h:205-215`), triggered per branch by `Expr::simplify()`
   (`.../pintool/expr.cpp:246-261`): the entire constraint subtree is
   converted to Z3 ASTs and run through the Z3 simplifier at branch time.
   **9.7% of XZ concolic CPU.**

## Method

`perf` was unavailable (`kernel.perf_event_paranoid=4`, no sudo), so we built
an `LD_PRELOAD` interposition shim ([builder](../../benchmarks/realworld/symprof/))
that wraps **all 108 exported `_sym_*` runtime functions** and **688 Z3 C API
functions** with `rdtsc` timing + call counting. Z3 calls only occur inside
runtime functions, so "inside libz3" is a clean lower attribution bound; the
remainder is QSYM runtime + target + RSan + shim overhead.

Overhead caveats: the shim adds ~60–100 cycles per wrapped call and a ~20 ms
TSC calibration per process; absolute numbers are inflated (XZ: 3.49 s
shimmed vs 3.50 s unshimmed — inflation is small here because the dominant
cost is inside few, expensive Z3 calls). Runs are standalone (no AFL
forkserver); one-time init costs (~17–20 ms Z3 context/runtime init) are
amortized across a whole campaign under the forkserver and are called out
separately.

Raw data: `xz-concolic.txt`, `xz-concrete.txt`, `xml-concolic.txt`,
`xml-concrete.txt` in this directory.

## XZ/liblzma (valid seed, 228 B, concolic)

Total CPU ≈ 3,485 ms (shimmed; unshimmed wall ≈ 3,594 ms — the run ends in a
`FATAL` at `expr.h:443`, see Finding F7).

| Layer | Calls | Time | Share |
|---|---:|---:|---:|
| `Z3_ast_to_string` (per-branch dedup) | 10,343 | 2,898 ms | **82.7%** |
| `Z3_simplify_ex` (eager per-node simplify) | 55,658 | 339 ms | **9.7%** |
| Z3 AST constructors / params / config | ~1.25 M | ~59 ms | 1.7% |
| **Everything else** (QSYM DAG builder, shadow memory, dep-forest, notify, target code, RSan, TCMalloc, shim) | — | ~209 ms | **6.0%** |
| — of which `_sym_notify_*` + `_sym_read/write_memory` + param/ret slots | ~45 K | ~2.1 ms | 0.06% |

Per-branch profile: 10,397 `_sym_push_path_constraint` calls; each pays one
full SMT-LIB rendering of its constraint (~280 µs average — constraints grow
with path depth, so this is superlinear in trace length).

Concrete mode for comparison (same binary, `SYMCC_NO_SYMBOLIC_INPUT=1`):
total CPU ≈ 17 ms (after removing the 20 ms shim calibration); all wrapped
SymCC scaffolding together costs **0.4 ms** — concrete-mode SymCC overhead is
negligible in absolute terms; the concrete gap vs `afl-cc` is the RSan layer
(see [overhead-breakdown](../overhead-breakdown/README.md)).

## libxml2 (valid seed, 30 B, concolic)

Total CPU ≈ 45 ms (after calibration removal; unshimmed wall ≈ 64 ms including
one-time init).

| Layer | Calls | Time | Share |
|---|---:|---:|---:|
| One-time init (Z3 context/config + runtime init) | — | ~17–20 ms | ~40% (standalone only; amortized under forkserver) |
| `Z3_ast_to_string` (per-branch dedup, 220 branches) | 220 | 10.3 ms | ~23% |
| `Z3_simplify_ex` | 836 | 4.7 ms | ~10% |
| `Z3_solver_assert` + AST constructors | ~450 | ~2.2 ms | ~5% |
| **All symbolic tracking** (DAG build + shadow + notify + slots) | ~8.6 K | **~0.5 ms** | **~1%** |
| Target + RSan + TCMalloc | — | remainder | — |

Under the AFL forkserver (init amortized), libxml2 concolic ≈ 52 ms vs
concrete ≈ 32 ms per exec — and ~15 ms of that delta is the two removable
artifacts above.

## Findings

- **F1 — Symbolic tracking itself is cheap.** DAG construction, shadow memory,
  basic-block/call/ret notifications, and parameter/return slots together are
  ~0.5–2 ms per execution (1–6% of concolic CPU). Concolic execution is
  **not** inherently 100–5600× concrete; the current gap is engineering, not
  fundamentals.
- **F2 — Per-branch `to_string()` dedup dominates.** `Solver::addIfUnique()`
  renders every branch constraint to SMT-LIB text for `constraint_set`
  membership (solver.cpp:119-124). Cost grows with constraint size →
  superlinear along the path. Replaceable by `Z3_get_ast_id()` keys (Z3
  hash-conses ASTs, so id equality ≈ syntactic equality) or by the
  memoized XXH32 structural hash that `Expr` already maintains.
- **F3 — Eager simplify-on-materialize.** `Expr::toZ3Expr()` runs the Z3
  simplifier (with `:pp.*` params) the first time each node is materialized,
  and `addJcc` forces materialization of the whole subtree per branch. This is
  a SymAFL-local modification; it can be gated or deferred to trace-dump time
  (or to the fuzzer-side PCBT, which re-parses the SMT anyway).
- **F4 — Constraint solving never happens in the target process.** No
  `check()`, no push/pop per branch (`negatePath` is commented out,
  solver.cpp:205-206). The only per-branch Z3 work is materialize → simplify →
  stringify → `solver.add`. So "concolic cost" in SymAFL-v1 is 100% tracing
  overhead, 0% solving — and most of it is *text rendering*.
- **F5 — `.pct` dump cost.** `save_solver_to_file()` (Runtime.cpp:440-475)
  serializes all new assertions at child exit — a second full `to_string()`
  pass over the same constraints in AFL mode. Unavoidable while the trace
  format is SMT text; removable with a binary trace format.
- **F6 — CallStackManager hashing is pure waste in v1.** `visitCall`/`visitRet`
  recompute an XXH32 over the whole call stack per call/ret
  (call_stack_manager.cpp:26-44); the result is only consumed by
  `PruneExprBuilder`, which is active only with `SYMCC_ENABLE_LINEARIZATION`.
  SymAFL-v1 never sets it.
- **F7 — XZ concolic correctness bug.** The valid-seed concolic execution dies
  at ~3.5 s with `FATAL ... expr.h:443: l->bits() == r->bits()` (bit-width
  mismatch building an expression), exit code 255. Under AFL this truncates
  the trace mid-path (atexit still dumps the partial `.pct`), which explains
  XZ's tiny PCBT (root + 2 leaves) and early PCBT exhaustion in the v1
  campaign. XZ conclusions are distorted until this is fixed. Note the
  earlier "XZ concolic ≈ 535.66 ms" average in
  [mode-timing](../mode-timing/README.md) was averaged over seeds; the valid
  seed alone is ≈ 3.59 s (168× its concrete 21.4 ms), mutants range
  32–415 ms.
- **F8 — Secondary inefficiencies** (worth fixing after F2/F3): GC is never
  invoked (no call sites for `_sym_collect_garbage`; threshold 5 M), the
  `CacheExprBuilder` hash-cons is a 1,024-entry FIFO that thrashes on long
  traces, and every `_sym_build_*` does two global `std::map` lookups in
  `allocatedExpressions`.

## Throughput economics (why this matters for PCBT)

Per-candidate cost with PCBT-ON:

```
t_candidate = t_screen + p_admit × t_concolic
```

- `t_screen` is fuzzer-side only (CheckInput Z3 query, **no target
  execution**): OpenJPEG's 8,943 cand/s implies ≈ 0.11 ms average.
- With current XZ `t_concolic` ≈ 3,594 ms (valid seed) even a 90% rejection
  rate leaves 360 ms/candidate — PCBT cannot win there. This is the user's
  concern, confirmed for deep-path targets.
- After F2+F3 fixes: XZ `t_concolic` ≈ 200–350 ms (12–17× faster), libxml2
  ≈ 35–40 ms (~1.15–1.25× its concrete). The PCBT advantage zone then extends
  from "extreme-rejection targets only" (OpenJPEG 99.65%) to most structured
  parsers.

## Engineering proposals (ranked by effort/benefit)

| # | Change | Effort | Expected effect |
|---|---|---|---|
| P1 | `addIfUnique`: dedup via `Z3_get_ast_id` (or Expr XXH32) instead of `to_string()` | ~10 LoC in solver.cpp | Removes F2 → XZ concolic −83%, libxml2 −23% |
| P2 | Gate eager simplify behind env (default off); simplify at dump time or fuzzer-side | ~20 LoC (expr.h, solver.cpp, Config) | Removes F3 → another −10% |
| P3 | Skip `solver.add` during tracing; keep constraint `ExprRef`s and materialize Z3 only for the exit dump of queue-gaining runs | ~50 LoC | No-gain runs pay ~zero Z3 (libxml2: 873/935 admitted runs are no-gain) |
| P4 | No-op `visitCall`/`visitRet` when linearization is off | ~5 LoC + runtime flag | Removes F6 (small here, larger in call-heavy targets) |
| P5 | Invoke GC periodically (or from the pass) + enlarge `CacheExprBuilder` FIFO via env | ~20 LoC | Bounds long-run degradation (F8) |
| P6 | Fix the XZ `expr.h:443` bit-width FATAL | investigation | Correctness: restores full traces for XZ |
| P7 | Binary trace format (opcode + child indices + input-byte refs); materialize Z3 fuzzer-side only for branches the PCBT actually solves | days | Removes F5 and all target-side Z3; target process becomes pure DAG tracker (~1–3% overhead over concrete + RSan) |
| P8 | Taint-gated symbolization / LTO static slicing: only symbolize code reachable from input-derived values | days–weeks | Approaches dynamic-taint costs (2–5× concrete) for parser targets |

## Conclusion

Concolic execution is **not** doomed to extreme overhead. In SymAFL-v1 the
measured inherent cost of symbolic tracking is 1–6% of concolic CPU; ~90% is
spent rendering and simplifying constraint text per branch — artifacts that
can be removed or moved off the hot path without changing v1 semantics
(screen → concolic once → InsertTrace on coverage gain). P1+P2 alone should
cut concolic cost by ~5–17×; P3 makes non-gaining executions nearly
Z3-free, which is exactly the common case PCBT wants to make cheap.
