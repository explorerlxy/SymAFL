#!/usr/bin/env bash
# Build and measure original AFL++ (afl-cc) concrete baselines for selected targets.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SYMAFL_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../scripts/symafl-env.sh
source "$SYMAFL_ROOT/scripts/symafl-env.sh"

REALWORLD_ROOT="${REALWORLD_ROOT:-/media/hahafish/Data/ForUbuntu/test/Realworld}"
RESULT_ROOT="$SYMAFL_ROOT/results/throughput/aflcc-timing"
AFL_OUT_BASE="${AFL_OUT_BASE:-/tmp/symafl-realworld}"
HARNESS_DIR="$SCRIPT_DIR/harness"
AFL_CC="$AFL_PATH/afl-cc"
AFL_CXX="$AFL_PATH/afl-cc"
FUZZ_SECONDS="${FUZZ_SECONDS:-30}"
FUZZ_TIMEOUT="${FUZZ_TIMEOUT:-2000}"
CFLAGS="-O1 -g"

mkdir -p "$RESULT_ROOT"

build_xz() {
  local name=xz
  local dir="$REALWORLD_ROOT/$name"
  local build="$dir/build/aflcc-lib"
  rm -rf "$build"
  cmake -S "$dir/src" -B "$build" -G Ninja \
    -DCMAKE_C_COMPILER="$AFL_CC" \
    -DCMAKE_C_FLAGS="$CFLAGS" \
    -DBUILD_SHARED_LIBS=OFF -DXZ_NLS=OFF -DXZ_DOC=OFF \
    -DENABLE_SMALL=ON -DALLOW_CLMUL_CRC=OFF
  ninja -C "$build" liblzma
  local lib="$(find "$build" -name liblzma.a -print -quit)"
  "$AFL_CC" $CFLAGS -I"$dir/src/src/liblzma/api" -I"$HARNESS_DIR" \
    "$HARNESS_DIR/xz_harness.c" "$lib" -o "$dir/build/xz-aflcc"
}

build_libxml2() {
  local name=libxml2
  local dir="$REALWORLD_ROOT/$name"
  local build="$dir/build/aflcc-lib"
  rm -rf "$build"
  cmake -S "$dir/src" -B "$build" -G Ninja \
    -DCMAKE_C_COMPILER="$AFL_CC" \
    -DCMAKE_C_FLAGS="$CFLAGS" \
    -DBUILD_SHARED_LIBS=OFF -DLIBXML2_WITH_ZLIB=OFF \
    -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_PYTHON=OFF \
    -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_TESTS=OFF \
    -DLIBXML2_WITH_PROGRAMS=OFF
  ninja -C "$build" LibXml2
  local lib="$(find "$build" -name libxml2.a -print -quit)"
  "$AFL_CC" $CFLAGS -I"$dir/src/include" -I"$build" -I"$HARNESS_DIR" \
    "$HARNESS_DIR/xml_harness.c" "$lib" -lm -ldl -lpthread \
    -o "$dir/build/libxml2-aflcc"
}

measure_target() {
  local name="$1" bin="$2"
  local dir="$REALWORLD_ROOT/$name"
  local outdir="$RESULT_ROOT/$name"
  mkdir -p "$outdir"
  [[ -x "$bin" ]]

  "$SCRIPT_DIR/measure-mode-timing.py" \
    --target "$name-aflcc" --binary "$bin" \
    --input "$dir/seeds/valid" --input "$dir/seeds/malformed" \
    --concrete-reps 30 --concolic-reps 0 --timeout 30 \
    --output "$outdir/direct-summary.json" > "$outdir/direct-stdout.txt"

  local stamp="$(date -u +%Y%m%d-%H%M%S)"
  local afl_out="$AFL_OUT_BASE/$name-aflcc-$stamp"
  mkdir -p "$afl_out"
  set +e
  AFL_SKIP_BIN_CHECK=1 AFL_MAP_SIZE=65536 AFL_NO_UI=1 AFL_SKIP_CPUFREQ=1 \
    "$AFL_PATH/afl-fuzz" \
    -i "$dir/seeds" -o "$afl_out" -S "$name" \
    -m none -t "$FUZZ_TIMEOUT" -V "$FUZZ_SECONDS" -- "$bin" \
    > "$outdir/afl-fuzz.log" 2>&1
  local rc=$?
  set -e
  [[ -s "$afl_out/$name/fuzzer_stats" ]]
  cp "$afl_out/$name/fuzzer_stats" "$outdir/fuzzer_stats.txt"
  {
    printf 'target=%s\n' "$name"
    printf 'binary=%s\n' "$bin"
    printf 'compiler=%s\n' "$($AFL_CC --version | head -1)"
    printf 'afl_output=%s\n' "$afl_out"
    printf 'afl_rc=%s\n' "$rc"
    printf 'fuzz_seconds=%s\n' "$FUZZ_SECONDS"
    printf 'fuzz_timeout=%s\n' "$FUZZ_TIMEOUT"
  } > "$outdir/manifest.env"
  printf '[aflcc] PASS %s\n' "$name"
}

main() {
  local targets=("$@")
  if [[ ${#targets[@]} -eq 0 ]]; then
    targets=(xz libxml2)
  fi
  for name in "${targets[@]}"; do
    case "$name" in
      xz)
        build_xz
        measure_target xz "$REALWORLD_ROOT/xz/build/xz-aflcc"
        ;;
      libxml2)
        build_libxml2
        measure_target libxml2 "$REALWORLD_ROOT/libxml2/build/libxml2-aflcc"
        ;;
      *)
        printf 'unsupported aflcc target: %s\n' "$name" >&2
        return 2
        ;;
    esac
  done
}

main "$@"
