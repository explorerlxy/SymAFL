# SymAFL-v1 Real-World Benchmarks

This directory contains the versioned drivers and stdin harnesses for the
SymAFL-v1 real-world throughput test set. The checked-out sources, build trees,
logs, and generated binaries live outside Git under:

```text
/media/hahafish/Data/ForUbuntu/test/Realworld/
```

AFL output must stay on a Linux-native filesystem and is written to:

```text
/tmp/symafl-realworld/
```

## Targets

The default sequence is:

1. Zstd v1.5.5 — streaming frame decompression
2. XZ/liblzma v5.4.6 — streaming XZ decompression
3. OpenJPEG v2.5.2 — in-memory JP2/J2K decode
4. libtiff v4.5.1 — memory-backed `TIFFClientOpen` decode
5. libxml2 v2.11.8 — in-memory XML parse
6. SQLite v3.44.2 — SQL execution or `sqlite3_deserialize()` for database images

Each target is built as a small no-argument stdin driver linked with an
instrumented static library. This keeps symbolic input on fd 0 and avoids
file-only `@@` harnesses or shell wrappers.

## Usage

```bash
source scripts/symafl-env.sh
benchmarks/realworld/run-realworld.sh zstd       # one target
benchmarks/realworld/run-realworld.sh all        # sequential full suite
FUZZ_SECONDS=120 benchmarks/realworld/run-realworld.sh sqlite
```

The script clones and pins each upstream source, builds a static library with
RSan Clang and Full LTO, links the final binary with SafeStack + SymCC + QSYM,
verifies instrumentation, runs valid/malformed direct-input smoke tests, and
then starts a bounded `afl-fuzz -K` campaign.

## Metrics

The primary throughput metric is candidate throughput:

```text
pcbt_candidate_cnt / pcbt_wall_tm
```

It includes PCBT-rejected candidates and the candidate that triggers PCBT
exhaustion. `pcbt_concolic_exec_cnt`, `pcbt_no_cov_gain_cnt`, and
`pcbt_saturated_branch_cnt` are mechanism metrics; they are not substitutes for
candidate throughput. Post-exhaustion ordinary AFL executions are reported
separately through `con_exec_cnt` and the standard AFL statistics.

Per-target manifests, direct-run results, seed hashes, AFL output paths, and
copies of `sym_mode_stats` are stored in each target's `results/` directory.
Raw AFL output and build artifacts are intentionally not committed.
