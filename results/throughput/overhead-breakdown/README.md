# SymCC / RSan Concrete Overhead Breakdown

Date: 2026-07-27

This experiment separates the concrete-mode cost of the major SymAFL layers:

1. Original AFL++ `afl-cc` target.
2. RSan-only target (SafeStack + modified TCMalloc + custom linker, no SymCC).
3. SymCC-only target (SymCC instrumentation + QSYM runtime, no RSan).
4. Full SymAFL target (RSan + SymCC + QSYM).

RSan-only binaries are built directly with RSan clang and therefore do not
contain AFL forkserver coverage instrumentation. They can be used for direct
process timing, but not for AFL throughput comparison.

## Direct process timing

Median wall time for the valid seed, 30 repetitions:

| Target | `afl-cc` | RSan-only | SymCC-only | Full SymAFL concrete |
|---|---:|---:|---:|---:|
| XZ/liblzma | 1.248 ms | 15.720 ms | 3.395 ms | 15.791 ms |
| libxml2 | 1.244 ms | 15.742 ms | 8.264 ms | 32.104 ms |

Direct process timing includes runtime initialization and process startup, so
it is useful for layer attribution but should not be interpreted as AFL
forkserver per-execution cost.

## AFL concrete throughput

| Target | `afl-cc` | SymCC-only concrete | Full SymAFL concrete OFF |
|---|---:|---:|---:|
| XZ/liblzma | 10,523.24 exec/s | 3,602.29 exec/s | 112.26 exec/s |
| libxml2 | 7,165.38 exec/s | 2,920.05 exec/s | 222.89 exec/s |

Relative slowdowns:

| Target | SymCC-only vs `afl-cc` | Full vs SymCC-only |
|---|---:|---:|
| XZ/liblzma | **2.92× slower** | **32.09× slower** |
| libxml2 | **2.45× slower** | **13.10× slower** |

Thus SymCC instrumentation has a real concrete-mode cost, but the full SymAFL
binary is much slower than SymCC-only. The remaining gap is dominated by the
RSan/SafeStack allocator/linker layer and by the fact that SafeStack-inserted
checks are themselves symbolized in the full build.

## Static instrumentation scale

Counts are static call instructions in the final binary, not dynamic counts,
but they show the amount of code inserted by the compiler pipeline.

| Target | Binary | Size | `_sym_notify_basic_block` calls | `_sym_*` runtime calls |
|---|---|---:|---:|---:|
| XZ | `afl-cc` | 1 MB | 0 | 0 |
| XZ | RSan-only | 1 MB | 0 | 0 |
| XZ | SymCC-only | 2 MB | 1,052 | 18,757 |
| XZ | Full SymAFL | 3 MB | 3,275 | 39,203 |
| libxml2 | `afl-cc` | 6 MB | 0 | 0 |
| libxml2 | RSan-only | 3 MB | 0 | 0 |
| libxml2 | SymCC-only | 9 MB | 14,881 | 175,768 |
| libxml2 | Full SymAFL | 27 MB | 40,151 | 414,874 |

The full build contains roughly twice as many SymCC runtime call sites as the
SymCC-only build. This is expected: SafeStack runs first and inserts new
memory-safety branches, and the SymCC pass runs after SafeStack and symbolizes
those branches too.

## Why concrete mode is still expensive

`SYMCC_NO_SYMBOLIC_INPUT=1` or `*__symbolic=0` disables symbolic input
creation. It does **not** remove compiler-inserted instrumentation.

Concrete mode still executes the following layers:

1. **Per-basic-block notification**
   - `_sym_notify_basic_block(site_id)` calls
     `CallStackManager::visitBasicBlock(site_id)`.
   - Calls and returns also update the QSYM call-stack state; call/ret paths
     recompute an XXH32 hash over the call stack even when no symbolic value
     exists.
   - These calls execute even when every value is concrete.

2. **Short-circuit checks around symbolic computations**
   - `Symbolizer::shortCircuitExpressionUses()` wraps symbolic runtime calls in
     checks that test whether all input expressions are null.
   - In concrete mode the slow path is skipped, but the null checks, branches,
     PHIs, and runtime-call scaffolding still execute.
   - Each guard requires extra blocks in the CFG, so the compiled program has
     substantially more branches and basic blocks than the original target.

3. **Shadow-memory reads and writes**
   - Every instrumented load calls `_sym_read_memory`; every instrumented store
     calls `_sym_write_memory`. These calls are not removed in concrete mode.
   - The common concrete path still checks whether an address belongs to an
     allocated shadow page, including a lookup in the shadow-page map.
   - libc wrappers such as `read`, `fread`, string functions, and allocation
     wrappers maintain shadow state around intercepted buffers.

4. **Parameter, return, and allocator bookkeeping**
   - Function arguments and returns still write/read expression slots.
   - Calls such as `malloc`/`calloc`/`realloc`/`free` are redirected at
     individual call sites to symbolized wrappers.
   - Concrete mode avoids creating symbolic bytes, but wrapper dispatch and
     shadow maintenance remain.

5. **QSYM runtime and cache footprint**
   - With `SYMCC_NO_SYMBOLIC_INPUT=1`, QSYM returns before creating the Z3
     context and solver, so Z3 solving is not the main concrete-mode cost in
     the standalone/direct baseline.
   - In an AFL `-K` process without that environment override, the runtime
     constructor runs before the first per-fork `*__symbolic` read, so the Z3
     context, solver, expression builder, signal handlers, and forkserver are
     initialized before any concrete child is selected.
   - The runtime still loads configuration, initializes libc wrappers, signal
     handling, forkserver/SHM state, call-stack state, and expression maps.
   - The larger binary and extra data structures increase instruction-cache,
     data-cache, and branch-predictor pressure.

6. **Full-build amplification**
   - The pipeline is `SafeStackLegacyPass → SymbolizeLegacyPass →
     StackProtectorPass`.
   - SymCC sees and symbolizes RSan-inserted checks, so the full binary has
     substantially more SymCC call sites than the SymCC-only binary.

## What concrete mode actually disables

Concrete mode disables:

- symbolic marking of stdin bytes;
- symbolic expression creation from input values;
- Z3 solver/context initialization in the QSYM `NoInput` path;
- solver work and path-constraint accumulation.

Concrete mode does not disable:

- SymCC compiler-inserted runtime calls;
- basic-block/call/return notification;
- short-circuit checks;
- shadow-memory tracking;
- allocator and libc wrappers;
- AFL coverage instrumentation;
- RSan SafeStack and allocator checks.

## Conclusion

The concrete-mode overhead is not caused by Z3 solving. It is primarily the
cost of keeping a symbolic-execution runtime and shadow machine attached to
every execution, plus the compiler-inserted checks needed to decide at run
time whether values are concrete or symbolic.

For these two targets, the breakdown is:

- SymCC-only is about **2.5–3× slower** than an original AFL++ binary in
  concrete AFL mode.
- Full SymAFL is another **13–32× slower** than SymCC-only.
- Therefore, SymCC instrumentation is a real overhead source, but it is not
  the only—or even the largest—source in the full SymAFL binary. RSan and the
  symbolization of RSan-inserted checks are major contributors.

## Raw evidence

- `xz/rsan-only/` and `xz/symcc-only/`
- `libxml2/rsan-only/` and `libxml2/symcc-only/`
- `../aflcc-timing/`
- `../mode-timing/`
- Builder: `benchmarks/realworld/run-overhead-breakdown.sh`
