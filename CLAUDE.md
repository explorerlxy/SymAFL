# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SymAFL is a hybrid fuzzing system that integrates **AFL++** (coverage-guided fuzzing), **RSan** (RangeSanitizer — spatial/temporal memory error detection), and **SymCC** (compiler-based concolic execution) into a single toolchain. Its core contribution is **Path Constraint Binary Tree (PCBT)**-guided seed screening: before concretely executing each mutated seed, a Z3 solver checks whether the seed can trigger a new branch in the PCBT. Only "interesting" seeds that pass this screening are concretely executed, avoiding the high cost of executing low-value seeds.

### Repository Layout

```
SymAFL/
├── AFLplusplus/          # Modified AFL++ with PCBT integration
│   ├── src/
│   │   ├── PathConTree.cpp      # ~1800 LOC — PCBT core: CheckInput, InsertTrace, FocusCheck
│   │   ├── afl-fuzz.c           # Main fuzzer loop — symcc_mode guard, PCBT calls
│   │   └── afl-fuzz-run.c       # fuzz_one(): CheckInput → execute → InsertTrace
│   └── include/
│       ├── PathConTree.hpp      # C API for PCBT (extern "C" wrappers)
│       └── afl-fuzz.h           # symcc_mode, path_con_tree fields, stats counters
├── RSan/                  # RangeSanitizer — modified LLVM 16 + TCMalloc
│   ├── llvm-project-16/llvm/lib/CodeGen/
│   │   ├── SafeStack.cpp        # RSan SafeStack pass (BZHI→SHL+SHR replacements)
│   │   ├── SymCC/
│   │   │   ├── Pass.cpp         # ~350 LOC — shouldInstrument(), AFL globals, ctx injection
│   │   │   ├── Symbolizer.cpp   # ~1200 LOC — per-instruction symbolic IR injection
│   │   │   └── Runtime.cpp/h    # Runtime function declarations
│   │   └── TargetPassConfig.cpp # Pass pipeline: SafeStack → SymCC → StackProtector
│   ├── tcmalloc-implicit/       # Modified TCMalloc (implicit size/mem tagging)
│   └── linker-implicit/         # Custom linker scripts + dynamic linker (pld.so)
└── symcc/
    ├── runtime/                 # SymCC runtime library (libsymcc-rt)
    │   └── src/backends/
    │       ├── qsym/Runtime.cpp # ~820 LOC — forkserver, 5 SHM channels, reset_gconfig()
    │       └── simple/Runtime.cpp
    └── SYMCC_ANALYSIS_REPORT.md # Detailed analysis of SymCC internals
```

### Component Guides

Use the guide closest to the code being changed; these files own subsystem-specific build, test, and implementation details.

| Scope | Guide |
|---|---|
| PCBT algorithm, AFL++ queue/fuzz loop, and `-K` mode | [AFLplusplus/CLAUDE.md](AFLplusplus/CLAUDE.md) |
| Modified LLVM CodeGen, SafeStack, TCMalloc, and custom linker | [RSan/CLAUDE.md](RSan/CLAUDE.md) |
| SymCC runtime, QSYM/Simple backends, and runtime ABI | [symcc/CLAUDE.md](symcc/CLAUDE.md) |

### Key Architecture Decisions

1. **Pass pipeline**: `SafeStackLegacyPass` → `SymbolizeLegacyPass` → `StackProtectorPass`. SymCC runs AFTER SafeStack so it can symbolically track RSan-injected bounds-check branches. This is what enables "vulnerability → path" binding.

2. **LTO-only instrumentation**: Both SafeStack and SymCC run during the CodeGen phase of Full LTO linking (`-flto=full`). They are NOT active during per-TU compilation. SymCC is opt-in via `-Wl,-plugin-opt=-enable-symcc` (default: off).

3. **Per-call-site interception**: `Symbolizer::handleFunctionCall()` redirects calls like `malloc` → `malloc_symbolized` at each call site, not globally. This prevents SafeStack runtime functions (`__noinstrument_*`) from being affected.

4. **Selective instrumentation**: `shouldInstrument()` in Pass.cpp skips `__noinstrument_*`, `__safestack_init`, `__interceptor_*`, and SymCC's own constructor functions.

5. **BMI2 elimination**: RSan originally used `llvm.x86.bmi.bzhi.64` for pointer tag extraction. This was replaced with generic `SHL+SHR` in 4 locations in SafeStack.cpp to avoid `X86ISD::BZHI` instruction selection crashes.

6. **5 shared-memory channels**: coverage bitmap (`__afl_area_ptr`), output directory (`__out_dir`), symbolic mode switch (`__symbolic`), queue entry ID (`__queue_entry_id`), insert depth (`__insert_depth`).

7. **Dual-mode runtime**: `reset_gconfig()` in the QSYM runtime reads `*__symbolic` before each fork. `0` → `inputFileDescriptor = -1` (pure concrete, no symbolic computation). `1` → `inputFileDescriptor = 0` (stdin is symbolic, Z3 solves path constraints).

## Build Commands

### Environment Setup (required before any build)

```bash
git clone --recurse-submodules git@github.com:explorerlxy/SymAFL.git
cd SymAFL
source scripts/symafl-env.sh
```

This derives `SYMAFL_ROOT` from the script location and sets `RSAN_C`, `RT_DIR`, `AFL_PATH`, and other required variables. Every path can be overridden by pre-setting the corresponding variable.

> **Path note:** The repository is self-locating; no symlink or fixed checkout path is required. On NTFS/fuseblk checkouts, set `git config core.filemode false` in each component repository to avoid phantom mode-change diffs.

### Build / Rebuild RSan LLVM (with integrated SymCC pass)

```bash
cd $SYMAFL_ROOT/RSan
source env.sh
cd $RSAN_LLVM_BUILD
ninja LLVMCodeGen clang lld
```

Verify SymCC pass is linked:
```bash
nm $RSAN_LLVM_BUILD/lib/libLLVMCodeGen.a | grep "createSymCC"
# Expected: 0000000000000000 T createSymCCSymbolizePass()
```

Full LLVM build from scratch (one-time):
```bash
cd $SYMAFL_ROOT/RSan
source env.sh
./install-all.sh
```

### Build All Three Subsystems (one command)

```bash
scripts/build-all.sh            # rsan -> symcc -> aflpp, in dependency order
scripts/build-all.sh rsan       # or build a single subsystem: rsan | symcc | aflpp
scripts/build-all.sh rsan symcc # or list several targets explicitly
```

Each stage is idempotent (ninja/make/incremental guards) and verifies its own
output (e.g. SymCC pass present in `libLLVMCodeGen.a`). `symcc` requires the
RSan clang, so it must come after `rsan`.

### Build SymCC Runtime

**QSYM backend** (recommended — full features: path pruning, `.pct` persistence, deduplication):
```bash
source $SYMAFL_ROOT/scripts/symafl-env.sh
cd $SYMAFL_ROOT/symcc/runtime
cmake -G Ninja \
  -DCMAKE_C_COMPILER=$RSAN_C -DCMAKE_CXX_COMPILER=$RSAN_CXX \
  -DCMAKE_BUILD_TYPE=Release -DSYMCC_RT_BACKEND=qsym \
  -DLLVM_VERSION=16 -DLLVM_DIR=$RSAN_LLVM_BUILD/lib/cmake/llvm \
  -DZ3_TRUST_SYSTEM_VERSION=ON \
  -S . -B /tmp/symcc-rt-qsym && ninja -C /tmp/symcc-rt-qsym
```

**Simple backend** (no LLVM dependency, basic Z3 solving):
```bash
cmake -G Ninja \
  -DCMAKE_C_COMPILER=$RSAN_C -DCMAKE_CXX_COMPILER=$RSAN_CXX \
  -DCMAKE_BUILD_TYPE=Release -DSYMCC_RT_BACKEND=simple \
  -DZ3_TRUST_SYSTEM_VERSION=ON \
  -S . -B /tmp/symcc-rt-simple && ninja -C /tmp/symcc-rt-simple
```

### Build Target Programs

**Quick** (one command):
```bash
source $SYMAFL_ROOT/scripts/symafl-env.sh
symafl-build --symcc read.c -o read
```

**Manual** (full SymAFL — RSan + SymCC):
```bash
source $SYMAFL_ROOT/scripts/symafl-env.sh
$RSAN_C -O2 -fno-builtin-malloc -fno-builtin-calloc \
  -fno-builtin-realloc -fno-builtin-free \
  -g -flto=full -fsanitize=safe-stack \
  -fuse-ld=lld -no-pie \
  -T $RSAN_LDS -z max-page-size=0x1000 \
  -Wl,--dynamic-linker=$RSAN_PLD \
  -L$RSAN_TC/lib/ -Wl,-rpath,$RSAN_TC/lib/ \
  -Wl,-plugin-opt=-enable-symcc \
  target.c \
  -L$RT_DIR -lsymcc-rt -lz3 -lpthread -ldl \
  -Wl,-rpath,$RT_DIR \
  -ltcmalloc_minimal -o target
```

**RSan only** (no SymCC, omit `-Wl,-plugin-opt=-enable-symcc` and the symcc-rt libraries):
```bash
$RSAN_C -O2 -fno-builtin-malloc ... -flto=full -fsanitize=safe-stack ... target.c -ltcmalloc_minimal -o target-safe
```

Key build flags:
- `-enable-symcc`: controls SymCC instrumentation (LTO: `-Wl,-plugin-opt=-enable-symcc`, non-LTO: `-mllvm -enable-symcc`)
- `-fsanitize=safe-stack`: controls RSan SafeStack
- SymCC and SafeStack are independently controlled

### Verify Build Result

```bash
# Check SymCC instrumentation ran (look for SafeStack artifacts in SymCC warnings)
$RSAN_C ... 2>&1 | grep "Warning"

# Confirm main() is instrumented
nm target | grep "U _sym_notify_basic_block"  # should have output
nm target | grep "U __afl_area_ptr"            # should have output

# Check malloc_symbolized only in application code, not SafeStack runtime
objdump -t target | grep "malloc_symbolized"
```

### Run Fuzzing

```bash
source $SYMAFL_ROOT/scripts/symafl-env.sh
symafl-fuzz ./target
# or manual:
AFL_SKIP_BIN_CHECK=1 AFL_MAP_SIZE=65536 \
afl-fuzz -i seeds -o /tmp/output -K -m none -t 1000+ -- ./target
```

**Critical**: Output directory (`-o`) must be on ext4/xfs, not NTFS (AFL++ uses `:` in queue entry filenames which NTFS rejects).

### Run Standalone (without AFL++)

```bash
# Concrete mode (RSan only)
./symafl_runner ./target-symafl 20

# Symbolic mode (Z3 path exploration)
echo "AAAA" | ./symafl_runner -s ./target-symafl
```

`symafl_runner` pre-creates the SHM segments that the SymCC runtime's forkserver expects. Not needed when running under AFL++.

## Testing Checklist

After making changes, verify:

1. **LLVM build**: `ninja LLVMCodeGen clang lld` succeeds
2. **SymCC pass exists**: `nm $RSAN_LLVM_BUILD/lib/libLLVMCodeGen.a | grep createSymCC` has output
3. **Compile test program**: LTO build with `-Wl,-plugin-opt=-enable-symcc` succeeds (no BZHI crash)
4. **Instrumentation verification**: `nm target | grep "_sym_notify_basic_block"` has output; `__noinstrument_*` functions reference `malloc` (not `malloc_symbolized`)
5. **Runtime**: OOB access → SIGTRAP (exit 133); valid access → normal return; symbolic mode → Z3 path exploration output
6. **PCBT persistence**: Crash produces `.pct-XXXXXX` file in output dir

## Source File Map — Where to Make Changes

| Change | File |
|--------|------|
| PCBT algorithm (CheckInput/InsertTrace/FocusCheck) | `AFLplusplus/src/PathConTree.cpp` |
| PCBT C API | `AFLplusplus/include/PathConTree.hpp` |
| AFL fuzz loop integration | `AFLplusplus/src/afl-fuzz-run.c` |
| New AFL stats/settings for SymAFL | `AFLplusplus/include/afl-fuzz.h` |
| SymCC pass — instrumentation decisions | `RSan/llvm-project-16/llvm/lib/CodeGen/SymCC/Pass.cpp` |
| SymCC pass — per-instruction symbolization | `RSan/llvm-project-16/llvm/lib/CodeGen/SymCC/Symbolizer.cpp` |
| SymCC pass — runtime function declarations | `RSan/llvm-project-16/llvm/lib/CodeGen/SymCC/Runtime.cpp` |
| SymCC pass — module-level instrumentation (AFL globals, ctors) | `RSan/llvm-project-16/llvm/lib/CodeGen/SymCC/Pass.cpp:instrumentModule()` |
| Pass pipeline order | `RSan/llvm-project-16/llvm/lib/CodeGen/TargetPassConfig.cpp:addISelPrepare()` |
| RSan SafeStack pointer tagging (tag bits, base loc) | `RSan/llvm-project-16/llvm/lib/CodeGen/SafeStack.cpp` |
| Runtime — forkserver, SHM, reset_gconfig() | `symcc/runtime/src/backends/qsym/Runtime.cpp` |
| Build orchestrator (all subsystems) | `scripts/build-all.sh` |
| Build script (one-command compile) | `scripts/symafl-build` |
| Fuzz script (one-command AFL++) | `scripts/symafl-fuzz` |
| Env vars (`RSAN_C`, `RT_DIR`, `AFL_PATH`, etc.) | `scripts/symafl-env.sh` |

## Known Pitfalls

- **`-flto=full` is mandatory**: SymCC and SafeStack only run during LTO CodeGen. Compiling without `-flto=full` produces uninstrumented code.
- **Output dir must be on ext4/xfs**: NTFS cannot handle `:` in AFL queue entry names (`id:000000,...`).
- **`RSan/env.sh` no longer changes cwd** and derives `RSAN_TOP` from its own location; prefer `scripts/symafl-env.sh` for the integrated workflow.
- **Non-LTO builds**: `-mllvm -enable-symcc` passes the flag in per-TU mode, but SymAFL is designed for LTO.
- **`inputFileDescriptor` matters**: Just changing `g_config.input` is not enough for mode switching — `inputFileDescriptor` controls whether `read_symbolized()` actually creates symbolic expressions. Set to `-1` for true concrete execution.
- **Stubs compiled with GCC, not RSan clang**: Runtime stubs must use plain GCC to prevent recursive instrumentation by SymCC.
