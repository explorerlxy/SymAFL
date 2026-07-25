#!/bin/bash
#=============================================================================
# SymAFL one-shot build driver
#
# Usage:
#   scripts/build-all.sh                 # build all three subsystems in order
#   scripts/build-all.sh all             # same as above
#   scripts/build-all.sh rsan            # RSan: LLVM 16 + TCMalloc-implicit + linker
#   scripts/build-all.sh symcc           # SymCC QSYM runtime (needs RSan clang)
#   scripts/build-all.sh aflpp           # AFL++ (PCBT-enabled fuzzer)
#   scripts/build-all.sh rsan symcc      # multiple targets in one invocation
#
# Dependency order: RSan clang -> SymCC runtime. AFL++ is independent.
# Every stage is idempotent; already-built artifacts are skipped by the
# underlying build systems (ninja/make/install-all.sh guards).
#=============================================================================
set -euo pipefail

_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
_SYMAFL_ROOT_GUESS="$(cd -- "$_SCRIPT_DIR/.." && pwd -P)"
export SYMAFL_ROOT="${SYMAFL_ROOT:-$_SYMAFL_ROOT_GUESS}"

# Loads RSAN_C, RSAN_LLVM_BUILD, RT_DIR, AFL_PATH, ... (warnings are expected
# for pieces that have not been built yet)
# shellcheck source=symafl-env.sh
source "$_SCRIPT_DIR/symafl-env.sh"

log() { printf '\n\033[1;32m[build-all]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build-all] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- RSan: modified LLVM 16 + TCMalloc-implicit + linker script + pld.so ---
build_rsan() {
    log "=== RSan: LLVM 16 + TCMalloc-implicit + custom linker ==="
    # install-all.sh locates the tree via $(pwd) — it must run from RSan/
    cd "$SYMAFL_ROOT/RSan"
    # shellcheck source=../RSan/env.sh
    source ./env.sh
    ./install-all.sh

    [[ -x "$RSAN_C" ]] || die "RSan clang missing after build: $RSAN_C"
    # NOTE: no `grep -q` here — with pipefail, grep -q exits on first match and
    # nm dies with SIGPIPE (141), making a successful check look like a failure.
    if nm "$RSAN_LLVM_BUILD/lib/libLLVMCodeGen.a" 2>/dev/null | grep createSymCC > /dev/null; then
        log "SymCC pass linked into libLLVMCodeGen.a ✓"
    else
        die "createSymCC* not found in libLLVMCodeGen.a — SymCC pass not linked?"
    fi
}

# --- SymCC QSYM runtime (built WITH the RSan clang, into RT_DIR's tree) ---
build_symcc() {
    log "=== SymCC QSYM runtime ==="
    [[ -x "$RSAN_C" ]] || die "RSan clang not built yet ($RSAN_C). Run first: $0 rsan"

    local build_dir="$SYMAFL_ROOT/symcc/qsym64build"
    cmake -G Ninja \
        -DCMAKE_C_COMPILER="$RSAN_C" -DCMAKE_CXX_COMPILER="$RSAN_CXX" \
        -DCMAKE_BUILD_TYPE=Release -DSYMCC_RT_BACKEND=qsym \
        -DLLVM_VERSION=16 -DLLVM_DIR="$RSAN_LLVM_BUILD/lib/cmake/llvm" \
        -DZ3_TRUST_SYSTEM_VERSION=ON \
        -S "$SYMAFL_ROOT/symcc/runtime" -B "$build_dir"
    ninja -C "$build_dir"

    ls "$build_dir"/libsymcc-rt.* >/dev/null 2>&1 \
        || die "libsymcc-rt not found in $build_dir"
}

# --- AFL++ with PCBT integration ---
build_aflpp() {
    log "=== AFL++ (PCBT-enabled) ==="
    make -C "$AFL_PATH" -j"$(nproc)"
    [[ -x "$AFL_PATH/afl-fuzz" ]] || die "afl-fuzz missing after build: $AFL_PATH/afl-fuzz"
}

usage() { sed -n '3,15p' "$0"; exit "${1:-0}"; }

targets=()
for arg in "$@"; do
    case "$arg" in
        all)                targets+=(rsan symcc aflpp) ;;
        rsan)               targets+=(rsan) ;;
        symcc)              targets+=(symcc) ;;
        aflpp|afl|afl++)    targets+=(aflpp) ;;
        -h|--help)          usage 0 ;;
        *)                  echo "Unknown target: $arg" >&2; usage 1 ;;
    esac
done
[[ ${#targets[@]} -eq 0 ]] && targets=(rsan symcc aflpp)

log "Targets: ${targets[*]}"
for t in "${targets[@]}"; do
    "build_$t"
done

log "Build finished: ${targets[*]}"
