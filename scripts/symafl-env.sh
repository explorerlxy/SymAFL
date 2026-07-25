#!/bin/bash
#=============================================================================
# SymAFL Environment Setup
# Usage: source symafl-env.sh        (from repository root)
#    or: source scripts/symafl-env.sh (when installed under scripts/)
#
# All paths are derived from this script's location. Every component path
# can be overridden by pre-setting the corresponding variable.
#=============================================================================

# ---- Resolve SYMAFL_ROOT from the script location (no hard-coded paths) ----
_SYMAFL_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
if [[ -d "$_SYMAFL_SCRIPT_DIR/AFLplusplus" && -d "$_SYMAFL_SCRIPT_DIR/RSan" ]]; then
    # Script sits at the repository root
    _SYMAFL_DEFAULT_ROOT="$_SYMAFL_SCRIPT_DIR"
else
    # Script sits one level down (e.g. scripts/)
    _SYMAFL_DEFAULT_ROOT="$(cd -- "$_SYMAFL_SCRIPT_DIR/.." && pwd -P)"
fi
export SYMAFL_ROOT="${SYMAFL_ROOT:-$_SYMAFL_DEFAULT_ROOT}"

# ---- RSan LLVM 16 (with integrated SymCC pass) ----
export RSAN_LLVM_BUILD="${RSAN_LLVM_BUILD:-$SYMAFL_ROOT/RSan/llvm-build}"
export RSAN_C="${RSAN_C:-$RSAN_LLVM_BUILD/bin/clang}"
export RSAN_CXX="${RSAN_CXX:-$RSAN_LLVM_BUILD/bin/clang++}"

# ---- RSan TCMalloc + dynamic linker (implicit tagging) ----
export RSAN_TC="${RSAN_TC:-$SYMAFL_ROOT/RSan/tcmalloc-impl-build}"
export RSAN_LDS="${RSAN_LDS:-$SYMAFL_ROOT/RSan/linker-implicit/globals/linkglobals.ld}"
export RSAN_PLD="${RSAN_PLD:-$SYMAFL_ROOT/RSan/linker-implicit/libdl/pld.so}"

# ---- SymCC QSYM Runtime (LLVM 16 build) ----
export RT_DIR="${RT_DIR:-$SYMAFL_ROOT/symcc/qsym64build/lib}"

# ---- AFL++ ----
export AFL_PATH="${AFL_PATH:-$SYMAFL_ROOT/AFLplusplus}"
export AFL_SKIP_BIN_CHECK="${AFL_SKIP_BIN_CHECK:-1}"
export AFL_SKIP_CPUFREQ="${AFL_SKIP_CPUFREQ:-1}"
export AFL_MAP_SIZE="${AFL_MAP_SIZE:-65536}"

# ---- SymAFL output dir (must be on ext4/xfs, not NTFS) ----
export SYMAFL_OUTDIR_BASE="${SYMAFL_OUTDIR_BASE:-/tmp/symafl-outputs}"

# ---- PATH (idempotent) ----
for _p in "$AFL_PATH" "$RSAN_LLVM_BUILD/bin" "$SYMAFL_ROOT/scripts"; do
    [[ -d "$_p" ]] || continue
    case ":$PATH:" in
        *":$_p:"*) ;;
        *) export PATH="$_p:$PATH" ;;
    esac
done
unset _p

# ---- Preflight checks (warnings only; staged builds may legitimately miss pieces) ----
_symafl_warn() { printf 'symafl-env: WARNING: %s\n' "$1" >&2; }
[[ -x "$RSAN_C" ]]            || _symafl_warn "RSan clang not executable: $RSAN_C (build LLVM first)"
[[ -e "$RSAN_LDS" ]]          || _symafl_warn "linker script missing: $RSAN_LDS"
[[ -e "$RSAN_PLD" ]]          || _symafl_warn "custom dynamic linker missing: $RSAN_PLD"
[[ -e "$RT_DIR/libsymcc-rt.a" || -e "$RT_DIR/libsymcc-rt.so" ]] \
                            || _symafl_warn "symcc runtime library not found in: $RT_DIR"
[[ -x "$AFL_PATH/afl-fuzz" ]] || _symafl_warn "afl-fuzz not built in: $AFL_PATH"

echo "SymAFL environment loaded:"
echo "  SYMAFL_ROOT = $SYMAFL_ROOT"
echo "  RSAN_C      = $RSAN_C"
echo "  RT_DIR      = $RT_DIR"
echo "  AFL_PATH    = $AFL_PATH"
echo "  OUTDIR      = $SYMAFL_OUTDIR_BASE"
