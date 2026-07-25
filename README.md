# SymAFL

SymAFL is a hybrid fuzzing system that combines **AFL++**, **RSan (RangeSanitizer)**, and **SymCC**. It uses lightweight dynamic symbolic execution to build a **Path Constraint Binary Tree (PCBT)** and screens mutated inputs with Z3 before executing them concretely. Inputs that cannot reach an unexplored branch are rejected without launching the target, while promising inputs are executed and used to extend the tree.

The project is designed to bind memory-safety detection and path exploration: RSan turns spatial and temporal memory-safety checks into executable branches, and SymCC tracks those branches symbolically. Consequently, an input that can reach an RSan error state can be selected by the same path-guided mechanism used for ordinary program branches.

> **Current platform scope:** The integrated SymAFL workflow is intended for **x86_64 Linux**. RSan has other architecture-specific modes, but the SymAFL scripts and implicit-tagging workflow documented here target x86_64.

## How it works

```text
                         build time
 source program ───────────────────────────────────────────────────────┐
      │                                                               │
      ▼                                                               │
 Full LTO CodeGen                                                     │
      ├─ RSan SafeStack: stack separation, metadata, bounds checks   │
      └─ SymCC SymbolizePass: symbolic expressions, path constraints, │
         AFL edge instrumentation, and runtime initialization         │
                                                                      │
                                                                      ▼
                    instrumented target + libsymcc-rt
                                                                      │
                                                                      │ run time
                                                                      ▼
 AFL++ mutator ──► PCBT/Z3 pre-screen ─┬─ reject: no concrete run
                                      │
                                      └─ accept: forkserver execution
                                                   │
                              concrete/symbolic mode via shared memory
                                                   │
                         coverage + RSan checks + incremental .pct trace
                                                   │
                              queue admission + PCBT trace insertion
```

### Main components

| Component | Role | Important locations |
|---|---|---|
| **AFL++** | Mutation, queue management, forkserver coordination, and coverage accounting. | [`AFLplusplus/src/afl-fuzz-run.c`](AFLplusplus/src/afl-fuzz-run.c), [`AFLplusplus/src/afl-fuzz.c`](AFLplusplus/src/afl-fuzz.c) |
| **PathConTree** | Z3-backed binary tree of explored path constraints; performs pre-screening and focus-mode exploration. | [`AFLplusplus/src/PathConTree.cpp`](AFLplusplus/src/PathConTree.cpp), [`AFLplusplus/include/PathConTree.hpp`](AFLplusplus/include/PathConTree.hpp) |
| **RSan** | SafeStack-derived spatial and temporal memory-error detection using allocation metadata and tagged pointers. | [`RSan/llvm-project-16/llvm/lib/CodeGen/SafeStack.cpp`](RSan/llvm-project-16/llvm/lib/CodeGen/SafeStack.cpp) |
| **SymCC pass** | Compiler-based symbolic expression tracking, path-constraint collection, AFL instrumentation, and libc interception. | [`RSan/llvm-project-16/llvm/lib/CodeGen/SymCC/`](RSan/llvm-project-16/llvm/lib/CodeGen/SymCC/) |
| **SymCC runtime** | QSYM/Simple symbolic runtime, Z3 solving, AFL forkserver, shared-memory attachment, and `.pct` persistence. | [`symcc/runtime/src/backends/qsym/Runtime.cpp`](symcc/runtime/src/backends/qsym/Runtime.cpp) |

## Repository layout

```text
SymAFL/
├── AFLplusplus/                 Modified AFL++ and PathConTree integration (submodule)
│   ├── src/PathConTree.cpp      PCBT implementation
│   ├── src/afl-fuzz-run.c      Mutation screening and target execution
│   └── include/PathConTree.hpp  C API used by afl-fuzz
├── RSan/                        Modified LLVM 16, SafeStack, TCMalloc, linker (submodule)
│   └── llvm-project-16/         Integrated SymCC CodeGen pass
├── symcc/                       SymCC compiler + vendored runtime sources (submodule)
│   └── runtime/                 Simple and QSYM runtime backends
├── scripts/                     symafl-env.sh / symafl-build / symafl-fuzz
├── config/compatibility.yaml    Cross-component version and ABI contract
├── tests/fixtures/              Source-only end-to-end fixtures (e.g. simpletest)
├── docs/                        Theory model, testing workflow, migration notes
├── CLAUDE.md                    Repository and subsystem development guide
└── README.md
```

## Requirements

The supported setup is a Linux x86_64 development system with the following major dependencies:

- Modified **LLVM/Clang/LLD 16.0.6** from `RSan/llvm-project-16`.
- **Z3** development headers and libraries.
- CMake, Ninja, GCC/G++, and standard build tools.
- Python 3; RSan's test tooling also uses `psutil` and `terminaltables`.
- Modified **TCMalloc** and the RSan custom dynamic linker, built as part of the RSan setup.
- A Linux-native output filesystem such as **ext4** or **xfs**.

The runtime stubs must be compiled without the RSan/SymCC compiler to avoid recursive instrumentation; use a regular GCC for such stubs.

### Important constraints

1. **Full LTO is required.** The integrated SafeStack and SymCC CodeGen passes run at the LTO link stage. Target builds must use `-flto=full`.
2. **SymCC is opt-in.** SafeStack is controlled by `-fsanitize=safe-stack`; SymCC is enabled at LTO link time with `-Wl,-plugin-opt=-enable-symcc`.
3. **Use a native Linux output directory.** AFL++ queue names contain `:`, which commonly fails on NTFS-mounted paths. Use `/tmp` or another ext4/xfs path for `-o`.
4. **The repository is self-locating.** `scripts/symafl-env.sh` derives `SYMAFL_ROOT` and every component path from its own location; override any of them by pre-setting the corresponding environment variable. No symlink or fixed checkout path is required.
5. **The RSan compiler change is local to SafeStack.** The RSan SafeStack pass replaces the problematic BMI2 `BZHI` IR with generic `LShr`/`Shl`; this should not be interpreted as a guarantee that every modified allocator or benchmark build is BMI2-independent.

## Quick start

### 1. Load the environment

From the repository root:

```bash
git clone --recurse-submodules git@github.com:explorerlxy/SymAFL.git
cd SymAFL
source scripts/symafl-env.sh
```

`SYMAFL_ROOT` is derived automatically. This sets `RSAN_C`, `RSAN_CXX`, the RSan linker/TCMalloc paths, `RT_DIR`, `AFL_PATH`, AFL defaults, the `scripts/` directory on `PATH`, and the default output base `/tmp/symafl-outputs`.

If the modified LLVM has not been built, build the required components first:

```bash
cd "$SYMAFL_ROOT/RSan"
source env.sh
cd "$RSAN_LLVM_BUILD"
ninja LLVMCodeGen clang lld
```

Verify that the integrated pass is present:

```bash
nm "$RSAN_LLVM_BUILD/lib/libLLVMCodeGen.a" | grep createSymCC
```

A full RSan bootstrap is available through `RSan/install-all.sh`; see [`RSan/README.md`](RSan/README.md) and [`RSan/CLAUDE.md`](RSan/CLAUDE.md) for the complete dependency and build procedure.

### 2. Build a target

Create a small input-driven program, for example:

```c
// read.c
#include <stdio.h>

int main(void) {
  char input[32] = {0};
  size_t n = fread(input, 1, sizeof(input) - 1, stdin);
  if (n >= 2 && input[0] == 'A' && input[1] == 'B')
    puts("interesting");
  return 0;
}
```

Build the complete RSan + SymCC target:

```bash
symafl-build --symcc read.c -o read-symafl
```

Useful variants:

```bash
symafl-build read.c -o read-rsan       # RSan SafeStack, no SymCC
symafl-build --no-rsan --symcc read.c  # SymCC without RSan SafeStack
symafl-build -O0 --symcc main.c util.c -o myapp
```

The helper always uses `-flto=full`, disables builtin allocator replacements, and links the custom RSan allocator/linker by default. `--symcc` adds `libsymcc-rt`, Z3, pthread, and `dl`.

### 3. Run AFL++ in SymAFL mode

The launcher creates a default seed and places output under `/tmp` when no paths are specified:

```bash
symafl-fuzz ./read-symafl
```

Or provide a seed directory and output directory explicitly:

```bash
mkdir -p seeds
printf 'AAAA' > seeds/seed1
symafl-fuzz ./read-symafl seeds /tmp/read-symafl-output
```

The launcher invokes AFL++ with the SymAFL `-K` mode, unlimited target memory, and a default `1000+` ms timeout. For advanced AFL++ options, invoke `afl-fuzz` directly because the convenience script intentionally supports only a small argument surface:

```bash
AFL_SKIP_BIN_CHECK=1 AFL_MAP_SIZE=65536 \
  "$AFL_PATH/afl-fuzz" \
  -i seeds -o /tmp/read-symafl-output -K -m none -t 1000+ -- ./read-symafl
```

`-K` optionally accepts an initial symbolic declaration count, for example `-K2048`; the default in the modified AFL++ code is 1024.

## PCBT screening and execution flow

For each mutation, AFL++ calls `path_con_tree_check_input()` before writing the candidate to the target or starting a concrete run:

1. The candidate bytes are bound to the corresponding Z3 byte variables (`k!0`, `k!1`, ...).
2. The PCBT is traversed from the root. Each node checks whether the candidate satisfies the known path constraint and whether an unexplored opposite branch can be reached.
3. A candidate that does not open a new branch is discarded without a target execution.
4. An accepted candidate receives an insertion depth and queue-entry identifier through shared memory.
5. The target executes under the AFL forkserver. If the candidate is retained, its incremental SMT trace is inserted into the PCBT.
6. When the current tree reaches its configured exploration limit, AFL++ can emit a final PCBT visualization and leave SymAFL screening mode.

The PCBT API is exposed through [`PathConTree.hpp`](AFLplusplus/include/PathConTree.hpp). Internally, [`PathConNode::check`](AFLplusplus/src/PathConTree.cpp) performs the per-node solver check, `CheckInput()` returns the insertion decision, and `InsertTrace()` parses the target's SMT-LIB trace and extends the tree. Focus mode narrows solving and mutation to a selected unexplored target node when normal fuzzing stops making progress.

### Return values used by `CheckInput()`

| Value | Meaning |
|---:|---|
| `0` | No PCBT root exists yet; the candidate is allowed to initialize exploration. |
| `>0` | An unexplored branch was found; the value identifies the insertion depth. |
| `-1` | The candidate does not open a new branch and should be skipped. |
| `-2` | The recorded exploration is exhausted; AFL++ finalizes the PCBT and disables this mode. |

## Runtime ABI and shared memory

The modified QSYM runtime attaches to five SysV shared-memory channels established by AFL++:

| Channel | Purpose |
|---|---|
| `__AFL_SHM_ID` | Coverage bitmap (`__afl_area_ptr`). |
| `__AFL_SHM_OUTDIR_ENV_ID` | AFL output directory used for solver traces. |
| `__AFL_SHM_SYMBOLIC_ENV_ID` | Concrete/symbolic mode (`0`/`1`). |
| `__AFL_SHM_QUEUE_ENTRY_ID` | Current queue-entry identifier. |
| `__AFL_SHM_INSERT_DEPTH__ID` | First solver assertion belonging to the current incremental trace. |

Before every fork, `reset_gconfig()` reads the symbolic-mode channel:

- `0`: `NoInput`, `inputFileDescriptor = -1`; reads remain concrete and do not construct symbolic expressions.
- `1`: `StdinInput`, `inputFileDescriptor = 0`; stdin reads are symbolized for path-constraint collection.

Changing only the high-level input configuration is insufficient: `inputFileDescriptor` is what the libc wrappers use to decide whether to call `_sym_make_symbolic`.

## Artifacts and diagnostics

A successful SymAFL run may produce:

- `output/queue/.pct-XXXXXX`: incremental SMT-LIB constraints saved for a queue entry, especially on a crash or abnormal exit.
- `output/queue/.PathConTree-*`: PCBT snapshots/final visualizations, depending on the configured visualization backend.
- `output/sym_mode_stats`: counts and timing for pre-screening, concrete execution, focus execution, and solver activity.

A `.pct-*` file can be inspected with Z3:

```bash
z3 /tmp/read-symafl-output/queue/.pct-000042
```

The QSYM runtime also installs signal and exit handling so that solver state can be persisted before the original signal behavior is restored.

## Verifying an instrumented target

After building a SymCC target, inspect the binary:

```bash
nm read-symafl | grep '_sym_notify_basic_block'
nm read-symafl | grep '__afl_area_ptr'
objdump -t read-symafl | grep malloc_symbolized
```

Expected behavior:

- The application contains SymCC basic-block and AFL coverage references.
- `malloc_symbolized` and similar wrappers are redirected at application call sites only.
- SafeStack runtime functions such as `__noinstrument_*` continue calling the original allocator functions.
- A valid memory access returns normally.
- An RSan-detected OOB/UAF reaches an `int3` breakpoint and normally reports exit status 133 (`SIGTRAP`).
- Symbolic mode emits satisfiable path constraints and can persist a `.pct-*` file.

### End-to-end checklist

1. Build `LLVMCodeGen`, `clang`, and `lld` with Ninja.
2. Confirm `createSymCCSymbolizePass` is present in `libLLVMCodeGen.a`.
3. Build a target with `-flto=full` and `-Wl,-plugin-opt=-enable-symcc`.
4. Confirm `_sym_notify_basic_block` and `__afl_area_ptr` references with `nm`.
5. Run valid and invalid RSan test cases.
6. Run a symbolic input test and verify Z3 constraints.
7. Run AFL++ with `-K` on an ext4/xfs output directory and verify PCBT/`.pct` artifacts.

For runtime changes, run both the SymCC runtime test suite and an AFL++ `-K` integration run; they exercise different parts of the system.

## Design details

### SafeStack before SymCC

The CodeGen pass order is deliberately:

```text
SafeStackLegacyPass → SymbolizeLegacyPass → StackProtectorPass
```

This allows SymCC to observe and symbolize RSan-inserted bounds-check branches. The SymCC pass skips SafeStack/runtime implementation functions, SymCC constructors, compiler-rt interceptors, and functions marked with LLVM's `DisableSanitizerInstrumentation` attribute.

### Per-call-site interception

The SymCC pass does not globally rename `malloc`, `read`, or `memcpy`. Instead, [`Symbolizer::handleFunctionCall()`](RSan/llvm-project-16/llvm/lib/CodeGen/SymCC/Symbolizer.cpp) redirects calls individually to `*_symbolized`. This prevents SafeStack's own allocator and initialization code from being recursively instrumented.

### BZHI replacement

The x86 SafeStack implementation originally used the BMI2 `BZHI` intrinsic while recovering allocation bases from tagged pointers. The modified pass uses generic right-shift/left-shift operations instead, avoiding the LLVM X86 instruction-selection failure associated with `X86ISD::BZHI`.

## Building components manually

The helper scripts are recommended for normal use. For subsystem development, see:

- [`AFLplusplus/CLAUDE.md`](AFLplusplus/CLAUDE.md) — PCBT algorithm, `-K` mode, AFL++ build and fuzz loop.
- [`RSan/CLAUDE.md`](RSan/CLAUDE.md) — modified LLVM, SafeStack, TCMalloc, linker, and RSan tests.
- [`symcc/CLAUDE.md`](symcc/CLAUDE.md) — SymCC runtime ABI and backend details.
- [`docs/SymAFL_TESTING_WORKFLOW.md`](docs/SymAFL_TESTING_WORKFLOW.md) — detailed Chinese testing workflow and expected outputs.
- [`docs/theory/THEORY_MODEL.md`](docs/theory/THEORY_MODEL.md) — applicability conditions and theoretical foundation of the PCBT.
- [`symcc/SYMCC_ANALYSIS_REPORT.md`](symcc/SYMCC_ANALYSIS_REPORT.md) — SymCC internals and instrumentation analysis.

Typical runtime builds are:

```bash
# QSYM backend (recommended)
cmake -G Ninja \
  -DCMAKE_C_COMPILER="$RSAN_C" \
  -DCMAKE_CXX_COMPILER="$RSAN_CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYMCC_RT_BACKEND=qsym \
  -DLLVM_VERSION=16 \
  -DLLVM_DIR="$RSAN_LLVM_BUILD/lib/cmake/llvm" \
  -DZ3_TRUST_SYSTEM_VERSION=ON \
  -S "$SYMAFL_ROOT/symcc/runtime" -B /tmp/symcc-rt-qsym
ninja -C /tmp/symcc-rt-qsym

# Simple backend (no LLVM support library required)
cmake -G Ninja \
  -DCMAKE_C_COMPILER="$RSAN_C" \
  -DCMAKE_CXX_COMPILER="$RSAN_CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYMCC_RT_BACKEND=simple \
  -DZ3_TRUST_SYSTEM_VERSION=ON \
  -S "$SYMAFL_ROOT/symcc/runtime" -B /tmp/symcc-rt-simple
ninja -C /tmp/symcc-rt-simple
```

## Known issues

- **`Cannot select: X86ISD::BZHI`**: rebuild using the modified `SafeStack.cpp`; the four pointer-base recovery paths must use `LShr`/`Shl`.
- **`malloc_symbolized` appears in `__noinstrument_*`**: ensure global interception renaming is absent and per-call-site redirection is used.
- **`undefined symbol: _sym_*`**: link the matching `libsymcc-rt` backend and its Z3/pthread/dl dependencies.
- **No PCBT output**: verify that AFL++ created and exported the output-directory SHM channel, and that the output path is writable and on ext4/xfs.
- **AFL++ reports “not instrumented”**: the modified target/runtime uses the custom AFL ABI; `AFL_SKIP_BIN_CHECK=1` is expected for this workflow.
- **No symbolic behavior in concrete mode**: confirm that the runtime switched `inputFileDescriptor` to `-1`; changing `g_config.input` alone does not disable symbolic reads.
- **Runtime recursive instrumentation or crashes**: compile non-instrumented stubs with regular GCC and leave SymCC disabled for those stubs.

## Research context

SymAFL builds on the ideas and implementations of:

- SymCC: compiler-based concolic execution.
- AFL++: coverage-guided fuzzing and forkserver execution.
- RangeSanitizer: efficient range checks for spatial and temporal memory safety.
- Lightweight dynamic symbolic execution for fuzzing throughput improvement.

See the detailed design notes and component documentation linked above for attribution, upstream references, and licensing information. Each integrated component retains its own license and contribution rules; consult its corresponding `README.md` before redistributing modified binaries or source.
