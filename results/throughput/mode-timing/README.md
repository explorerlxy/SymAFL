# Concrete vs Concolic Timing — XZ/liblzma and libxml2

Date: 2026-07-27

This directory contains direct mode-timing measurements for the question:
“How much slower is concolic execution than concrete execution for XZ/liblzma
and libxml2?”

Two evidence sources are used:

1. **AFL in-situ timing** — the most relevant metric for throughput. Concrete
   cost comes from AFL dry-run calibration and the PCBT-OFF baseline; concolic
   cost comes from `pcbt_concolic_exec_tm` in the fixed-timeout diagnostics.
2. **Standalone direct timing** — the same binary and input executed as a new
   process with `SYMCC_NO_SYMBOLIC_INPUT=1` (concrete) or with default QSYM
   symbolic stdin (concolic). This includes process/runtime startup, so it is
   useful as a distribution check but compresses ratios for short executions.

## AFL in-situ result

| Target | Concrete calibration mean | OFF baseline mean | Concolic mean | Concolic / calibration | Concolic / OFF baseline |
|---|---:|---:|---:|---:|---:|
| XZ/liblzma | 5.166 ms | 8.909 ms | 535.66 ms | **103.7×** | **60.1×** |
| libxml2 | 3.251 ms | 4.486 ms | 27.65 ms | **8.50×** | **6.16×** |

Definitions:

- Concrete calibration mean is AFL's dry-run timing before mutation.
- OFF baseline mean is `1000 / baseline execs_per_sec`.
- Concolic mean is `1000 / pcbt_concolic_exec_per_second` from the fixed
  2000 ms diagnostic.

This is the primary answer for the fuzzing configuration: **liblzma's
concolic executions are roughly two orders of magnitude slower than its
concrete executions, while libxml2's are roughly 6–9× slower.**

## Standalone direct timing

Each input was measured with 20 concrete and 7 concolic repetitions after a
warm-up. Values below are median wall-clock times.

| Target | Input | Concrete | Concolic | Ratio |
|---|---|---:|---:|---:|
| XZ | valid seed | 15.791 ms | 3572.839 ms | **226.3×** |
| XZ | malformed seed | 15.680 ms | 31.746 ms | **2.02×** |
| XZ | queue id:000002 | 15.766 ms | 32.088 ms | **2.04×** |
| XZ | queue id:000010 | 31.804 ms | 264.540 ms | **8.32×** |
| XZ | queue id:000020 | 31.701 ms | 414.829 ms | **13.09×** |
| libxml2 | valid seed | 32.104 ms | 64.156 ms | **2.00×** |
| libxml2 | malformed seed | 31.895 ms | 64.277 ms | **2.02×** |
| libxml2 | queue id:000002 | 32.060 ms | 31.833 ms | **0.99×** |
| libxml2 | queue id:000010 | 32.005 ms | 64.259 ms | **2.01×** |
| libxml2 | queue id:000020 | 32.164 ms | 64.255 ms | **2.00×** |

Caveats:

- Standalone measurements include QSYM runtime and process startup, which is
  about 16–32 ms here. AFL's forkserver amortizes much of that cost.
- The XZ valid seed's standalone concolic run returned 255 after about 3.57 s;
  this is a real QSYM expression-construction failure for that input, not a
  successful decode. The AFL fixed-timeout run nevertheless provides successful
  concolic executions for other candidates and is the appropriate in-situ
  average.
- The small direct ratios for libxml2 do not contradict the 6–9× AFL result;
  the 32 ms startup/runtime floor hides most of the target-level difference.

## Why the original 5–7 ms timeout failed

The original runner used `-t 2000+`, allowing AFL to reduce the timeout based
on concrete dry-run calibration:

- XZ timeout became 7 ms while its average concolic execution is about 536 ms.
- libxml2 timeout became 5 ms while its average concolic execution is about
  28 ms.

Thus the admitted candidates were not failing because the inputs were
uninteresting; they were being killed before concolic execution could finish.

## Files

- `xz/summary.json` — direct timing samples for XZ/liblzma.
- `libxml2/summary.json` — direct timing samples for libxml2.
- `measure-mode-timing.py` in `benchmarks/realworld/` — measurement script.
