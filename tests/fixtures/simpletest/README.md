# simpletest — SymAFL end-to-end fixture

Minimal input-driven C program used to validate the full SymAFL toolchain:
RSan SafeStack + SymCC instrumentation + AFL++ `-K` (PCBT) screening.

Provenance: moved out of `AFLplusplus/test/symccTest/` during the 2026-07
repository migration. Prebuilt binaries are intentionally **not** tracked —
rebuild with the current toolchain:

```bash
source scripts/symafl-env.sh          # from the superproject root
scripts/symafl-build --symcc tests/fixtures/simpletest/read.c \
  -o tests/fixtures/simpletest/build/read-symafl
```

Seeds live in `seeds/` (`seed0`, `seed1`, `seed2`). Example fuzz run:

```bash
scripts/symafl-fuzz tests/fixtures/simpletest/build/read-symafl \
  tests/fixtures/simpletest/seeds /tmp/symafl-outputs/simpletest
```

Expected behavior of a healthy toolchain:

- `nm read-symafl | grep _sym_notify_basic_block` and `__afl_area_ptr` resolve;
- `afl-fuzz -K` creates the five SHM channels, accepts new-branch candidates,
  and persists `queue/.pct-*` traces;
- `output/sym_mode_stats` records screening/execution counters.
