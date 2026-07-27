#!/usr/bin/env bash
# Run a preliminary no-PCBT baseline for already built real-world targets.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SYMAFL_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../scripts/symafl-env.sh
source "$SYMAFL_ROOT/scripts/symafl-env.sh"

REALWORLD_ROOT="${REALWORLD_ROOT:-/media/hahafish/Data/ForUbuntu/test/Realworld}"
AFL_OUT_BASE="${AFL_OUT_BASE:-/tmp/symafl-realworld}"
FUZZ_SECONDS="${FUZZ_SECONDS:-60}"
FUZZ_TIMEOUT="${FUZZ_TIMEOUT:-2000+}"

TARGETS=(zstd xz openjpeg libtiff libxml2 sqlite)

binary_for() {
  case "$1" in
    zstd) printf '%s' "$REALWORLD_ROOT/zstd/build/zstd-symafl" ;;
    xz) printf '%s' "$REALWORLD_ROOT/xz/build/xz-symafl" ;;
    openjpeg) printf '%s' "$REALWORLD_ROOT/openjpeg/build/openjpeg-symafl" ;;
    libtiff) printf '%s' "$REALWORLD_ROOT/libtiff/build/libtiff-symafl" ;;
    libxml2) printf '%s' "$REALWORLD_ROOT/libxml2/build/libxml2-symafl" ;;
    sqlite) printf '%s' "$REALWORLD_ROOT/sqlite/build/sqlite-symafl" ;;
    *) return 2 ;;
  esac
}

run_one() {
  local name="$1"
  local dir="$REALWORLD_ROOT/$name"
  local bin="$(binary_for "$name")"
  local stamp="$(date -u +%Y%m%d-%H%M%S)"
  local out="$AFL_OUT_BASE/$name-baseline-$stamp"
  mkdir -p "$out" "$dir/logs" "$dir/results"

  [[ -x "$bin" && -s "$dir/seeds/valid" && -s "$dir/seeds/malformed" ]]

  set +e
  AFL_SKIP_BIN_CHECK=1 AFL_MAP_SIZE=65536 AFL_NO_UI=1 AFL_SKIP_CPUFREQ=1 \
    SYMCC_NO_SYMBOLIC_INPUT=1 \
    "$AFL_PATH/afl-fuzz" \
    -i "$dir/seeds" -o "$out" -S "$name" \
    -m none -t "$FUZZ_TIMEOUT" -V "$FUZZ_SECONDS" -- "$bin" \
    > "$dir/logs/afl-baseline.log" 2>&1
  local rc=$?
  set -e

  local stats="$out/$name/fuzzer_stats"
  [[ -s "$stats" ]]
  cp "$stats" "$dir/results/baseline_fuzzer_stats.txt"
  {
    printf 'baseline_output=%s\n' "$out"
    printf 'baseline_rc=%s\n' "$rc"
    printf 'baseline_mode=pcbt-off-concrete\n'
    printf 'fuzz_seconds=%s\n' "$FUZZ_SECONDS"
    printf 'fuzz_timeout=%s\n' "$FUZZ_TIMEOUT"
  } > "$dir/results/baseline-run.env"
  printf '[baseline] PASS %s: %s\n' "$name" "$out"
}

main() {
  local requested=("$@")
  if [[ ${#requested[@]} -eq 0 || "${requested[0]}" == all ]]; then
    requested=("${TARGETS[@]}")
  fi
  local failures=()
  for name in "${requested[@]}"; do
    set +e
    ( set -Eeuo pipefail; run_one "$name" )
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      failures+=("$name")
      printf '[baseline] BLOCKED %s (rc=%s)\n' "$name" "$rc" >&2
    fi
  done
  if [[ ${#failures[@]} -ne 0 ]]; then
    printf 'baseline failures: %s\n' "${failures[*]}" >&2
    return 1
  fi
}

main "$@"
