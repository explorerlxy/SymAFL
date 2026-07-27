# SymAFL-v1 Real-World Results — 2026-07-27

See [ANALYSIS_LOW_REJECTION.md](ANALYSIS_LOW_REJECTION.md) for the follow-up
analysis of XZ/liblzma and libxml2 rejection rates, timeout behavior, and
variable coverage-gain entries.

All six targets completed the required sequence: pinned clone, RSan + SymCC
Full-LTO build, instrumentation verification, direct valid/malformed smoke
test, and a bounded `afl-fuzz -K` throughput run. Direct smoke results were
`valid_rc=0` and `malformed_rc=1` for every target; no target saved a crash or
hang during these runs.

## PCBT-ON candidate throughput

| Target | Candidates | Admitted | Rejected | Exhausted | Rejection rate | Candidate/s | Concolic exec/s | Trace inserts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Zstd v1.5.5 | 44,809 | 8,227 | 36,582 | 0 | 81.64% | 721.70 | 152.29 | 1 |
| XZ/liblzma v5.4.6 | 293 | 255 | 37 | 1 | 12.63% | 65.46 | 61.34 | 2 |
| OpenJPEG v2.5.2 | 539,416 | 1,893 | 537,523 | 0 | 99.65% | 8,943.17 | 99.34 | 2 |
| libtiff v4.5.1 | 13,160 | 4,289 | 8,871 | 0 | 67.41% | 184.54 | 152.16 | 3 |
| libxml2 v2.11.8 | 7,422 | 7,403 | 19 | 0 | 0.26% | 104.49 | 156.49 | 2 |
| SQLite v3.44.2 | 3,638 | 3,495 | 143 | 0 | 3.93% | 50.20 | 72.80 | 2 |

XZ reached PCBT exhaustion during the run; its 11,379 post-exhaustion ordinary
executions are reported separately and are not included in the PCBT-active
candidate-throughput row.

## Preliminary PCBT-OFF comparison

The baseline used the same binaries, seeds, AFL timeout, memory policy, and
60-second budget, but omitted `-K` and set `SYMCC_NO_SYMBOLIC_INPUT=1` so every
candidate was concretely executed. This is a preliminary OFF baseline, not a
full CHECK-ONLY ablation.

| Target | PCBT-ON candidate/s | PCBT-OFF exec/s | ON/OFF ratio | Interpretation |
|---|---:|---:|---:|---|
| Zstd | 721.70 | 241.35 | **2.99×** | Clear candidate-throughput gain |
| XZ/liblzma | 65.46 | 112.26 | **0.58×** | PCBT exhausts quickly; no gain |
| OpenJPEG | 8,943.17 | 115.14 | **77.67×** | Strongest high-cost-target gain |
| libtiff | 184.54 | 163.12 | **1.13×** | Small gain |
| libxml2 | 104.49 | 222.89 | **0.47×** | Screening overhead dominates |
| SQLite | 50.20 | 134.65 | **0.37×** | Low rejection rate; no gain |

These results support the intended cost model: PCBT improves candidate
throughput when the rejection rate and avoided target-execution cost are high
(OpenJPEG, Zstd, and to a lesser extent libtiff). It can reduce throughput
when most candidates must be executed anyway (libxml2, SQLite, and the quickly
exhausted XZ case).

## Raw evidence

Raw manifests and statistics remain outside Git:

```text
/media/hahafish/Data/ForUbuntu/test/Realworld/<target>/results/
/tmp/symafl-realworld/
```

Useful per-target files:

- `manifest.env`
- `direct-smoke.txt`
- `sym_mode_stats.txt`
- `fuzzer_stats.txt`
- `baseline-run.env`
- `baseline_fuzzer_stats.txt`
- `seed-sha256.txt`
