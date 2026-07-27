# symprof — LD_PRELOAD timing shim for the SymCC/QSYM runtime

Profiles where time goes inside a SymAFL binary without `perf`
(works with `kernel.perf_event_paranoid=4`).

`gen_shim.py` generates an interposition library that wraps every exported
`_sym_*` function of `libsymcc-rt.so` (per-function counters) and every Z3 C
API function with ≤ 6 arguments (aggregate counter) with `rdtsc` timing.

## Build

```bash
python3 gen_shim.py          # writes shim.c / shim.s (paths are hardcoded at top)
gcc -shared -fPIC -O2 -o shim.so shim.c shim.s -ldl
```

## Use

```bash
# concolic (symbolic is the standalone default)
SYMPROF_OUT=out.txt LD_PRELOAD=$PWD/shim.so ./target < seeds/valid

# concrete
SYMPROF_OUT=out.txt SYMCC_NO_SYMBOLIC_INPUT=1 LD_PRELOAD=$PWD/shim.so ./target < seeds/valid

python3 analyze.py out.txt ...
```

Output: `TSC_HZ`, `CPU_NS` (rusage), then `<sym|z3> <name> <calls> <cycles>`
per function. The shim adds ~60–100 cycles per wrapped call and a ~20 ms TSC
calibration spin per process (included in `CPU_NS` — subtract it).

Limitations: functions with > 6 integer/pointer args are not wrapped (17 Z3
functions, none on QSYM's tracing path); nested wrapped calls are
double-counted (Z3 time is a subset of the enclosing `_sym_*` time); wrapper
symbols defined inside `libsymcc-rt.so` with `-Bsymbolic` semantics would be
missed (not the case here).

Used for: [symbolic-cost-breakdown](../../../results/throughput/symbolic-cost-breakdown/README.md).
