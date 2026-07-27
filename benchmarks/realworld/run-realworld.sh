#!/usr/bin/env bash
# Build and run the SymAFL-v1 real-world benchmark targets sequentially.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SYMAFL_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../scripts/symafl-env.sh
source "$SYMAFL_ROOT/scripts/symafl-env.sh"

REALWORLD_ROOT="${REALWORLD_ROOT:-/media/hahafish/Data/ForUbuntu/test/Realworld}"
AFL_OUT_BASE="${AFL_OUT_BASE:-/tmp/symafl-realworld}"
FUZZ_SECONDS="${FUZZ_SECONDS:-60}"
FUZZ_TIMEOUT="${FUZZ_TIMEOUT:-2000+}"
HARNESS_DIR="$SCRIPT_DIR/harness"

BASE_CFLAGS="-O1 -g -flto=full -fsanitize=safe-stack -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free"
SYM_LDFLAGS="-flto=full -fuse-ld=lld -no-pie -fsanitize=safe-stack -T $RSAN_LDS -z max-page-size=0x1000 -Wl,--dynamic-linker=$RSAN_PLD -L$RSAN_TC/lib -Wl,-rpath,$RSAN_TC/lib -Wl,-plugin-opt=-enable-symcc -L$RT_DIR -Wl,-rpath,$RT_DIR -lsymcc-rt -lz3 -lpthread -ldl -ltcmalloc_minimal"
LLVM_AR="$RSAN_LLVM_BUILD/bin/llvm-ar"
LLVM_RANLIB="$RSAN_LLVM_BUILD/bin/llvm-ranlib"

TARGETS=(zstd xz openjpeg libtiff libxml2 sqlite)

log() {
  printf '[realworld] %s\n' "$*"
}

target_dir() {
  printf '%s/%s' "$REALWORLD_ROOT" "$1"
}

prepare_dirs() {
  local name="$1"
  mkdir -p "$REALWORLD_ROOT" "$AFL_OUT_BASE" \
    "$(target_dir "$name")"/{build,seeds,logs,results}
}

clone_target() {
  local name="$1" url="$2" ref="$3"
  local dir="$(target_dir "$name")/src"
  prepare_dirs "$name"
  if [[ ! -d "$dir/.git" ]]; then
    log "clone $name from $url"
    git clone "$url" "$dir"
  fi
  git -C "$dir" config core.filemode false
  git -C "$dir" fetch --tags origin
  git -C "$dir" checkout --detach "$ref"
  git -C "$dir" rev-parse HEAD > "$(target_dir "$name")/results/source-commit.txt"
}

write_manifest() {
  local name="$1"
  local dir="$(target_dir "$name")"
  {
    printf 'target=%s\n' "$name"
    printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source_commit=%s\n' "$(cat "$dir/results/source-commit.txt")"
    printf 'symafl_root=%s\n' "$SYMAFL_ROOT"
    printf 'aflplusplus_commit=%s\n' "$(git -C "$SYMAFL_ROOT/AFLplusplus" rev-parse HEAD)"
    printf 'rsan_commit=%s\n' "$(git -C "$SYMAFL_ROOT/RSan" rev-parse HEAD)"
    printf 'symcc_commit=%s\n' "$(git -C "$SYMAFL_ROOT/symcc" rev-parse HEAD)"
    printf 'compiler=%s\n' "$($RSAN_C --version | head -1)"
    printf 'base_cflags=%s\n' "$BASE_CFLAGS"
    printf 'sym_ldflags=%s\n' "$SYM_LDFLAGS"
    printf 'fuzz_seconds=%s\n' "$FUZZ_SECONDS"
    printf 'fuzz_timeout=%s\n' "$FUZZ_TIMEOUT"
  } > "$dir/results/manifest.env"
}

verify_binary() {
  local bin="$1"
  [[ -x "$bin" ]]
  local symbols="${bin}.nm"
  nm "$bin" > "$symbols"
  grep -q '_sym_notify_basic_block' "$symbols"
  grep -q '__afl_area_ptr' "$symbols"
  rm -f "$symbols"
  log "instrumentation verified: $bin"
}

smoke_target() {
  local name="$1" bin="$2"
  local dir="$(target_dir "$name")"
  local valid="$dir/seeds/valid" malformed="$dir/seeds/malformed"
  [[ -s "$valid" && -s "$malformed" ]]

  set +e
  SYMCC_NO_SYMBOLIC_INPUT=1 "$bin" < "$valid" > "$dir/logs/direct-valid.stdout" 2> "$dir/logs/direct-valid.stderr"
  local valid_rc=$?
  SYMCC_NO_SYMBOLIC_INPUT=1 "$bin" < "$malformed" > "$dir/logs/direct-malformed.stdout" 2> "$dir/logs/direct-malformed.stderr"
  local malformed_rc=$?
  set -e

  if [[ $valid_rc -ne 0 ]]; then
    log "direct valid-input smoke failed for $name (rc=$valid_rc)"
    return 1
  fi
  if [[ $malformed_rc -eq 139 || $malformed_rc -eq 134 || $malformed_rc -eq 136 ]]; then
    log "malformed input crashed $name unexpectedly (rc=$malformed_rc)"
    return 1
  fi
  printf 'valid_rc=%s\nmalformed_rc=%s\n' "$valid_rc" "$malformed_rc" \
    > "$dir/results/direct-smoke.txt"
  log "direct smoke passed for $name (valid=$valid_rc malformed=$malformed_rc)"
}

run_fuzz() {
  local name="$1" bin="$2"
  local dir="$(target_dir "$name")"
  local stamp="$(date -u +%Y%m%d-%H%M%S)"
  local out="$AFL_OUT_BASE/$name-$stamp"
  mkdir -p "$out"
  log "run $name with PCBT for ${FUZZ_SECONDS}s; output: $out"

  set +e
  AFL_SKIP_BIN_CHECK=1 AFL_MAP_SIZE=65536 AFL_NO_UI=1 AFL_SKIP_CPUFREQ=1 \
    "$AFL_PATH/afl-fuzz" \
    -i "$dir/seeds" -o "$out" -S "$name" \
    -K -m none -t "$FUZZ_TIMEOUT" -V "$FUZZ_SECONDS" -- "$bin" \
    > "$dir/logs/afl-fuzz.log" 2>&1
  local fuzz_rc=$?
  set -e

  local stats="$out/$name/sym_mode_stats"
  if [[ ! -s "$stats" ]]; then
    log "missing sym_mode_stats for $name (afl rc=$fuzz_rc)"
    return 1
  fi
  if ! grep -Eq '^pcbt_candidate_cnt: [1-9][0-9]*' "$stats"; then
    log "no PCBT candidates recorded for $name"
    return 1
  fi
  if ! grep -Eq '^pcbt_concolic_exec_cnt: [1-9][0-9]*' "$stats"; then
    log "no admitted concolic executions recorded for $name"
    return 1
  fi

  cp "$stats" "$dir/results/sym_mode_stats.txt"
  cp "$out/$name/fuzzer_stats" "$dir/results/fuzzer_stats.txt"
  sha256sum "$dir/seeds"/* > "$dir/results/seed-sha256.txt"
  printf 'afl_output=%s\nafl_rc=%s\n' "$out" "$fuzz_rc" \
    > "$dir/results/afl-run.env"
  log "PCBT throughput run passed for $name"
}

build_zstd() {
  local name=zstd
  clone_target "$name" https://github.com/facebook/zstd.git v1.5.5
  local dir="$(target_dir "$name")"
  log "build $name static library"
  gmake -C "$dir/src/lib" libzstd.a -j"$(nproc)" \
    CC="$RSAN_C" AR="$LLVM_AR" RANLIB="$LLVM_RANLIB" \
    CFLAGS="$BASE_CFLAGS -DZSTD_LEGACY_SUPPORT=0"
  $RSAN_C $BASE_CFLAGS -I"$dir/src/lib" -I"$HARNESS_DIR" \
    "$HARNESS_DIR/zstd_harness.c" "$dir/src/lib/libzstd.a" \
    $SYM_LDFLAGS -o "$dir/build/zstd-symafl"
  command -v zstd >/dev/null
  printf 'SymAFL real-world zstd seed: repeated structured payload for decoder coverage.\n' \
    > "$dir/build/zstd-seed-payload.txt"
  zstd --content-size -q -c "$dir/build/zstd-seed-payload.txt" > "$dir/seeds/valid"
  [[ -s "$dir/seeds/valid" ]]
  printf 'not-a-zstd-frame' > "$dir/seeds/malformed"
  write_manifest "$name"
  verify_binary "$dir/build/zstd-symafl"
  smoke_target "$name" "$dir/build/zstd-symafl"
  run_fuzz "$name" "$dir/build/zstd-symafl"
}

build_xz() {
  local name=xz
  clone_target "$name" https://github.com/tukaani-project/xz.git v5.4.6
  local dir="$(target_dir "$name")"
  log "build $name static library"
  rm -rf "$dir/build/lib"
  cmake -S "$dir/src" -B "$dir/build/lib" -G Ninja \
    -DCMAKE_C_COMPILER="$RSAN_C" \
    -DCMAKE_C_FLAGS="$BASE_CFLAGS" \
    -DCMAKE_AR="$LLVM_AR" -DCMAKE_RANLIB="$LLVM_RANLIB" \
    -DCMAKE_C_EXE_LINKER_FLAGS="$SYM_LDFLAGS" \
    -DCMAKE_C_BYTE_ORDER=LITTLE_ENDIAN \
    -DBUILD_SHARED_LIBS=OFF -DXZ_NLS=OFF -DXZ_DOC=OFF \
    -DENABLE_SMALL=ON -DALLOW_CLMUL_CRC=OFF
  ninja -C "$dir/build/lib" liblzma
  local lib="$(find "$dir/build/lib" -name liblzma.a -print -quit)"
  [[ -n "$lib" ]]
  $RSAN_C $BASE_CFLAGS -I"$dir/src/src/liblzma/api" -I"$HARNESS_DIR" \
    "$HARNESS_DIR/xz_harness.c" "$lib" $SYM_LDFLAGS -o "$dir/build/xz-symafl"
  cp "$SYMAFL_ROOT/AFLplusplus/testcases/archives/common/xz/small_archive.xz" "$dir/seeds/valid"
  printf 'not-an-xz-stream' > "$dir/seeds/malformed"
  write_manifest "$name"
  verify_binary "$dir/build/xz-symafl"
  smoke_target "$name" "$dir/build/xz-symafl"
  run_fuzz "$name" "$dir/build/xz-symafl"
}

build_openjpeg() {
  local name=openjpeg
  clone_target "$name" https://github.com/uclouvain/openjpeg.git v2.5.2
  local dir="$(target_dir "$name")"
  log "build $name static library"
  rm -rf "$dir/build/lib"
  cmake -S "$dir/src" -B "$dir/build/lib" -G Ninja \
    -DCMAKE_C_COMPILER="$RSAN_C" \
    -DCMAKE_C_FLAGS="$BASE_CFLAGS" \
    -DCMAKE_AR="$LLVM_AR" -DCMAKE_RANLIB="$LLVM_RANLIB" \
    -DCMAKE_C_EXE_LINKER_FLAGS="$SYM_LDFLAGS" \
    -DCMAKE_C_BYTE_ORDER=LITTLE_ENDIAN \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_THIRDPARTY=ON -DBUILD_CODEC=OFF \
    -DBUILD_TESTING=OFF -DBUILD_DOC=OFF
  ninja -C "$dir/build/lib" openjp2
  local lib="$(find "$dir/build/lib" -name 'libopenjp2*.a' -print -quit)"
  [[ -n "$lib" ]]
  $RSAN_C $BASE_CFLAGS -I"$dir/src/src/lib/openjp2" \
    -I"$dir/build/lib/src/lib/openjp2" -I"$HARNESS_DIR" \
    "$HARNESS_DIR/openjpeg_harness.c" "$lib" $SYM_LDFLAGS -lm \
    -o "$dir/build/openjpeg-symafl"
  cp "$SYMAFL_ROOT/AFLplusplus/testcases/images/jp2/not_kitty.jp2" "$dir/seeds/valid"
  printf 'not-a-jpeg2000-image' > "$dir/seeds/malformed"
  write_manifest "$name"
  verify_binary "$dir/build/openjpeg-symafl"
  smoke_target "$name" "$dir/build/openjpeg-symafl"
  run_fuzz "$name" "$dir/build/openjpeg-symafl"
}

build_libtiff() {
  local name=libtiff
  clone_target "$name" https://gitlab.com/libtiff/libtiff.git v4.5.1
  local dir="$(target_dir "$name")"
  log "build $name static library"
  rm -rf "$dir/build/lib"
  cmake -S "$dir/src" -B "$dir/build/lib" -G Ninja \
    -DCMAKE_C_COMPILER="$RSAN_C" \
    -DCMAKE_CXX_COMPILER="/usr/bin/c++" \
    -DCMAKE_C_FLAGS="$BASE_CFLAGS" \
    -DCMAKE_AR="$LLVM_AR" -DCMAKE_RANLIB="$LLVM_RANLIB" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_BYTE_ORDER=LITTLE_ENDIAN -DSIZEOF_SIZE_T=8 \
    -DBUILD_SHARED_LIBS=OFF -Dcxx=OFF -Dtiff-tools=OFF -Dtiff-tests=OFF \
    -Dtiff-docs=OFF -Dtiff-contrib=OFF -Dzlib=OFF -Djpeg=OFF \
    -Dlzma=OFF -Dzstd=OFF -Dwebp=OFF -Dlerc=OFF -Dpixarlog=OFF
  ninja -C "$dir/build/lib" tiff
  local lib="$(find "$dir/build/lib" -name 'libtiff*.a' -print -quit)"
  [[ -n "$lib" ]]
  $RSAN_C $BASE_CFLAGS -I"$dir/src/libtiff" -I"$dir/build/lib/libtiff" \
    -I"$HARNESS_DIR" "$HARNESS_DIR/tiff_harness.c" "$lib" \
    $SYM_LDFLAGS -lm -o "$dir/build/libtiff-symafl"
  python3 - "$dir/seeds/valid" <<'PY'
import struct, sys
out = sys.argv[1]
entries = [
    (256, 4, 1, 1),    # ImageWidth
    (257, 4, 1, 1),    # ImageLength
    (258, 3, 1, 8),    # BitsPerSample
    (259, 3, 1, 1),    # Compression: none
    (262, 3, 1, 1),    # Photometric: BlackIsZero
    (273, 4, 1, 134),  # StripOffsets
    (277, 3, 1, 1),    # SamplesPerPixel
    (278, 4, 1, 1),    # RowsPerStrip
    (279, 4, 1, 1),    # StripByteCounts
    (284, 3, 1, 1),    # PlanarConfiguration
]
data = bytearray(b"II" + struct.pack("<HI", 42, 8))
data += struct.pack("<H", len(entries))
for tag, typ, count, value in entries:
    data += struct.pack("<HHI", tag, typ, count)
    if typ == 3:
        data += struct.pack("<HH", value, 0)
    else:
        data += struct.pack("<I", value)
data += struct.pack("<I", 0)
data += b"\x80"
with open(out, "wb") as f:
    f.write(data)
PY
  [[ -s "$dir/seeds/valid" ]]
  printf 'not-a-tiff-image' > "$dir/seeds/malformed"
  write_manifest "$name"
  verify_binary "$dir/build/libtiff-symafl"
  smoke_target "$name" "$dir/build/libtiff-symafl"
  run_fuzz "$name" "$dir/build/libtiff-symafl"
}

build_libxml2() {
  local name=libxml2
  clone_target "$name" https://gitlab.gnome.org/GNOME/libxml2.git v2.11.8
  local dir="$(target_dir "$name")"
  log "build $name static library"
  rm -rf "$dir/build/lib"
  cmake -S "$dir/src" -B "$dir/build/lib" -G Ninja \
    -DCMAKE_C_COMPILER="$RSAN_C" \
    -DCMAKE_C_FLAGS="$BASE_CFLAGS" \
    -DCMAKE_AR="$LLVM_AR" -DCMAKE_RANLIB="$LLVM_RANLIB" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_BYTE_ORDER=LITTLE_ENDIAN \
    -DBUILD_SHARED_LIBS=OFF -DLIBXML2_WITH_ZLIB=OFF \
    -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_PYTHON=OFF \
    -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_READLINE=OFF \
    -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF
  ninja -C "$dir/build/lib" LibXml2
  local lib="$(find "$dir/build/lib" -name 'libxml2.a' -print -quit)"
  [[ -n "$lib" ]]
  $RSAN_C $BASE_CFLAGS -I"$dir/src/include" -I"$dir/build/lib" \
    -I"$HARNESS_DIR" "$HARNESS_DIR/xml_harness.c" "$lib" \
    $SYM_LDFLAGS -lm -o "$dir/build/libxml2-symafl"
  printf '<root><value>1</value></root>\n' > "$dir/seeds/valid"
  printf '<root><unclosed>' > "$dir/seeds/malformed"
  write_manifest "$name"
  verify_binary "$dir/build/libxml2-symafl"
  smoke_target "$name" "$dir/build/libxml2-symafl"
  run_fuzz "$name" "$dir/build/libxml2-symafl"
}

build_sqlite() {
  local name=sqlite
  clone_target "$name" https://github.com/sqlite/sqlite.git version-3.44.2
  local dir="$(target_dir "$name")"
  mkdir -p "$dir/build/amalgamation"
  if [[ ! -s "$dir/build/amalgamation/sqlite3.c" ]]; then
    log "generate SQLite amalgamation"
    if ! (cd "$dir/src" && ./configure --disable-shared --enable-static \
          CC="$RSAN_C" BUILD_CC=cc CFLAGS="$BASE_CFLAGS" && \
          gmake sqlite3.c -j"$(nproc)"); then
      log "SQLite source build failed; use the matching release amalgamation"
      curl -fL https://www.sqlite.org/2023/sqlite-amalgamation-3440200.zip \
        -o "$dir/build/sqlite-amalgamation.zip"
      unzip -o "$dir/build/sqlite-amalgamation.zip" -d "$dir/build/amalgamation"
      local nested="$(find "$dir/build/amalgamation" -mindepth 1 -maxdepth 1 -type d -print -quit)"
      if [[ -n "$nested" ]]; then
        cp "$nested"/* "$dir/build/amalgamation/"
      fi
    else
      cp "$dir/src/sqlite3.c" "$dir/src/sqlite3.h" "$dir/build/amalgamation/"
    fi
  fi
  $RSAN_C $BASE_CFLAGS -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
    -DSQLITE_ENABLE_DESERIALIZE -I"$dir/build/amalgamation" -I"$HARNESS_DIR" \
    "$HARNESS_DIR/sqlite_harness.c" "$dir/build/amalgamation/sqlite3.c" \
    $SYM_LDFLAGS -lm -o "$dir/build/sqlite-symafl"
  printf 'CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (1); SELECT count(*) FROM t;\n' \
    > "$dir/seeds/valid"
  printf 'CREATE TABLE broken(; SELECT nonsense FROM nowhere;\n' \
    > "$dir/seeds/malformed"
  write_manifest "$name"
  verify_binary "$dir/build/sqlite-symafl"
  smoke_target "$name" "$dir/build/sqlite-symafl"
  run_fuzz "$name" "$dir/build/sqlite-symafl"
}

run_one() {
  set -Eeuo pipefail
  local name="$1"
  case "$name" in
    zstd) build_zstd ;;
    xz) build_xz ;;
    openjpeg) build_openjpeg ;;
    libtiff) build_libtiff ;;
    libxml2) build_libxml2 ;;
    sqlite) build_sqlite ;;
    *) printf 'unknown target: %s\n' "$name" >&2; return 2 ;;
  esac
}

main() {
  local requested=("$@")
  if [[ ${#requested[@]} -eq 0 || "${requested[0]}" == all ]]; then
    requested=("${TARGETS[@]}")
  fi

  local failures=()
  for name in "${requested[@]}"; do
    log "===== target: $name ====="
    set +e
    ( set -Eeuo pipefail; run_one "$name" )
    local rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      log "===== PASS: $name ====="
    else
      log "===== BLOCKED: $name (rc=$rc) ====="
      failures+=("$name")
    fi
  done

  if [[ ${#failures[@]} -ne 0 ]]; then
    printf 'blocked targets: %s\n' "${failures[*]}" >&2
    return 1
  fi
}

main "$@"
