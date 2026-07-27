#!/usr/bin/env bash
# Build RSan-only and SymCC-only overhead controls for selected targets.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SYMAFL_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../scripts/symafl-env.sh
source "$SYMAFL_ROOT/scripts/symafl-env.sh"

REALWORLD_ROOT="${REALWORLD_ROOT:-/media/hahafish/Data/ForUbuntu/test/Realworld}"
RESULT_ROOT="$SYMAFL_ROOT/results/throughput/overhead-breakdown"
AFL_OUT_BASE="${AFL_OUT_BASE:-/tmp/symafl-realworld}"
HARNESS_DIR="$SCRIPT_DIR/harness"
FUZZ_SECONDS="${FUZZ_SECONDS:-30}"
FUZZ_TIMEOUT="${FUZZ_TIMEOUT:-2000}"
COMMON_CFLAGS="-O1 -g -flto=full -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free"
RSAN_CFLAGS="$COMMON_CFLAGS -fsanitize=safe-stack"
RSAN_LDFLAGS="-flto=full -fuse-ld=lld -no-pie -fsanitize=safe-stack -T $RSAN_LDS -z max-page-size=0x1000 -Wl,--dynamic-linker=$RSAN_PLD -L$RSAN_TC/lib -Wl,-rpath,$RSAN_TC/lib -ltcmalloc_minimal"
SYMCC_LDFLAGS="-flto=full -fuse-ld=lld -no-pie -Wl,-plugin-opt=-enable-symcc -L$RT_DIR -Wl,-rpath,$RT_DIR -lsymcc-rt -lz3 -lpthread -ldl"
LLVM_AR="$RSAN_LLVM_BUILD/bin/llvm-ar"
LLVM_RANLIB="$RSAN_LLVM_BUILD/bin/llvm-ranlib"

mkdir -p "$RESULT_ROOT"

configure_common() {
  local name="$1" variant="$2" cflags="$3"
  local dir="$REALWORLD_ROOT/$name"
  local build="$dir/build/$variant-lib"
  local build_log="$dir/logs/$variant-build.log"
  mkdir -p "$dir/logs"
  : > "$build_log"
  rm -rf "$build"
  case "$name" in
    xz)
      cmake -S "$dir/src" -B "$build" -G Ninja \
        -DCMAKE_C_COMPILER="$RSAN_C" -DCMAKE_C_FLAGS="$cflags" \
        -DCMAKE_AR="$LLVM_AR" -DCMAKE_RANLIB="$LLVM_RANLIB" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_BYTE_ORDER=LITTLE_ENDIAN \
        -DBUILD_SHARED_LIBS=OFF -DXZ_NLS=OFF -DXZ_DOC=OFF \
        -DENABLE_SMALL=ON -DALLOW_CLMUL_CRC=OFF >> "$build_log" 2>&1
      ninja -C "$build" liblzma >> "$build_log" 2>&1
      find "$build" -name liblzma.a -print -quit
      ;;
    libxml2)
      cmake -S "$dir/src" -B "$build" -G Ninja \
        -DCMAKE_C_COMPILER="$RSAN_C" -DCMAKE_C_FLAGS="$cflags" \
        -DCMAKE_AR="$LLVM_AR" -DCMAKE_RANLIB="$LLVM_RANLIB" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_BYTE_ORDER=LITTLE_ENDIAN \
        -DBUILD_SHARED_LIBS=OFF -DLIBXML2_WITH_ZLIB=OFF \
        -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_PYTHON=OFF \
        -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_TESTS=OFF \
        -DLIBXML2_WITH_PROGRAMS=OFF >> "$build_log" 2>&1
      ninja -C "$build" LibXml2 >> "$build_log" 2>&1
      find "$build" -name libxml2.a -print -quit
      ;;
    *) return 2 ;;
  esac
}

build_variant() {
  local name="$1" variant="$2"
  local dir="$REALWORLD_ROOT/$name"
  local cflags ldflags extra_libs
  case "$variant" in
    rsan-only)
      cflags="$RSAN_CFLAGS"
      ldflags="$RSAN_LDFLAGS"
      extra_libs=""
      ;;
    symcc-only)
      cflags="$COMMON_CFLAGS"
      ldflags="$SYMCC_LDFLAGS"
      extra_libs=""
      ;;
    *) return 2 ;;
  esac
  local lib="$(configure_common "$name" "$variant" "$cflags")"
  [[ -n "$lib" ]]
  case "$name" in
    xz)
      "$RSAN_C" $cflags -I"$dir/src/src/liblzma/api" -I"$HARNESS_DIR" \
        "$HARNESS_DIR/xz_harness.c" "$lib" $ldflags $extra_libs \
        -o "$dir/build/xz-$variant"
      ;;
    libxml2)
      "$RSAN_C" $cflags -I"$dir/src/include" -I"$dir/build/$variant-lib" \
        -I"$HARNESS_DIR" "$HARNESS_DIR/xml_harness.c" "$lib" \
        $ldflags $extra_libs -lm -o "$dir/build/libxml2-$variant"
      ;;
  esac
}

measure_variant() {
  local name="$1" variant="$2"
  local dir="$REALWORLD_ROOT/$name"
  local bin="$dir/build/$name-$variant"
  local outdir="$RESULT_ROOT/$name/$variant"
  mkdir -p "$outdir"
  [[ -x "$bin" ]]

  "$SCRIPT_DIR/measure-mode-timing.py" \
    --target "$name-$variant" --binary "$bin" \
    --input "$dir/seeds/valid" --input "$dir/seeds/malformed" \
    --concrete-reps 30 --concolic-reps 0 --timeout 30 \
    --output "$outdir/direct-summary.json" > "$outdir/direct-stdout.txt"

  if [[ "$variant" == "rsan-only" ]]; then
    {
      printf 'target=%s\nvariant=%s\nbinary=%s\n' "$name" "$variant" "$bin"
      printf 'afl_output=unavailable-no-afl-instrumentation\n'
      printf 'note=RSan-only binaries built directly with RSan clang lack AFL forkserver coverage instrumentation\n'
    } > "$outdir/manifest.env"
    printf '[overhead] PASS %s/%s (direct only)\n' "$name" "$variant"
    return 0
  fi

  local stamp="$(date -u +%Y%m%d-%H%M%S)"
  local afl_out="$AFL_OUT_BASE/$name-$variant-$stamp"
  mkdir -p "$afl_out"
  set +e
  AFL_SKIP_BIN_CHECK=1 AFL_MAP_SIZE=65536 AFL_NO_UI=1 AFL_SKIP_CPUFREQ=1 \
    SYMCC_NO_SYMBOLIC_INPUT=1 \
    "$AFL_PATH/afl-fuzz" \
    -i "$dir/seeds" -o "$afl_out" -S "$name" \
    -m none -t "$FUZZ_TIMEOUT" -V "$FUZZ_SECONDS" -- "$bin" \
    > "$outdir/afl-fuzz.log" 2>&1
  local rc=$?
  set -e
  [[ -s "$afl_out/$name/fuzzer_stats" ]]
  cp "$afl_out/$name/fuzzer_stats" "$outdir/fuzzer_stats.txt"
  {
    printf 'target=%s\nvariant=%s\nbinary=%s\n' "$name" "$variant" "$bin"
    printf 'afl_output=%s\nafl_rc=%s\n' "$afl_out" "$rc"
    printf 'fuzz_seconds=%s\nfuzz_timeout=%s\n' "$FUZZ_SECONDS" "$FUZZ_TIMEOUT"
  } > "$outdir/manifest.env"
  printf '[overhead] PASS %s/%s\n' "$name" "$variant"
}

main() {
  local targets=("$@")
  if [[ ${#targets[@]} -eq 0 ]]; then
    targets=(xz libxml2)
  fi
  for name in "${targets[@]}"; do
    for variant in rsan-only symcc-only; do
      build_variant "$name" "$variant"
      measure_variant "$name" "$variant"
    done
  done
}

main "$@"
