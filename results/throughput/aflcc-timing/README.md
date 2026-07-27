# Original AFL++ Compiler Concrete Timing

Date: 2026-07-27

This directory contains the control experiment requested after the concrete
versus concolic timing analysis: build the same XZ/liblzma and libxml2 stdin
harnesses with the original AFL++ compiler (`afl-cc`), without RSan SafeStack,
modified TCMalloc, the custom RSan linker, or the QSYM runtime, then compare
pure concrete execution speed.

## AFL forkserver throughput

Both runs used the same seeds, the same AFL++ fuzzer, 30-second budget, and
fixed 2000 ms timeout.

| Target | SymAFL binary, concrete OFF | Original `afl-cc` binary | Speedup |
|---|---:|---:|---:|
| XZ/liblzma | 112.26 exec/s (8.908 ms/exec) | **10,523.24 exec/s** (0.095 ms/exec) | **93.74×** |
| libxml2 | 222.89 exec/s (4.487 ms/exec) | **7,165.38 exec/s** (0.140 ms/exec) | **32.15×** |

No crashes or timeouts were recorded in either `afl-cc` run.

## Standalone direct execution

Median wall time over 30 repetitions:

| Target | Input | SymAFL concrete | Original `afl-cc` concrete | Speedup |
|---|---|---:|---:|---:|
| XZ | valid | 15.791 ms | 1.248 ms | **12.65×** |
| XZ | malformed | 15.680 ms | 1.261 ms | **12.44×** |
| libxml2 | valid | 32.104 ms | 1.244 ms | **25.80×** |
| libxml2 | malformed | 31.895 ms | 1.235 ms | **25.83×** |

## Comparison with SymAFL concolic mode

Using the fixed-timeout SymAFL diagnostics:

| Target | Original `afl-cc` concrete | SymAFL concolic | Difference |
|---|---:|---:|---:|
| XZ/liblzma | 10,523.24 exec/s | 1.87 exec/s | **≈5,636×** |
| libxml2 | 7,165.38 exec/s | 36.18 exec/s | **≈198×** |

This confirms that the QSYM/SymCC/RSan runtime stack dominates raw execution
cost for these two targets. The original AFL++ compiler is useful as a pure
throughput baseline, but it does not provide RSan vulnerability detection,
symbolic path constraints, or PCBT screening evidence.

## Interpretation

The measured overhead has three layers:

1. Original AFL++ instrumented binary: fastest concrete execution.
2. SymAFL binary with `SYMCC_NO_SYMBOLIC_INPUT=1`: much slower concrete
   execution because the RSan/QSYM runtime, custom allocator/linker, and
   instrumentation remain present.
3. SymAFL binary in concolic mode: another large slowdown from symbolic
   expression construction and solver interaction.

Therefore, PCBT throughput gains should ultimately be reported against at
least two baselines:

- **SymAFL concrete OFF**: evaluates whether PCBT avoids executions within the
  same instrumented runtime.
- **Original AFL++ `afl-cc`**: evaluates the end-to-end cost of the complete
  SymAFL instrumentation stack relative to ordinary coverage-guided fuzzing.

For XZ and libxml2, the current SymAFL-v1 PCBT-ON configuration does not beat
the original `afl-cc` compiler in raw candidate throughput. OpenJPEG remains
the target where PCBT's high rejection rate has the strongest chance to close
part of that instrumentation overhead.

## Files

- `run-aflcc-timing.sh` in `benchmarks/realworld/` — build and measurement
  driver.
- `*/direct-summary.json` — standalone timing samples.
- `*/fuzzer_stats.txt` — AFL throughput results.
- `*/manifest.env` — compiler, output, and timeout metadata.
