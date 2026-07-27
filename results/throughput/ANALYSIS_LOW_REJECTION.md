# Low-Reject-Rate Analysis: XZ/liblzma and libxml2

Date: 2026-07-27

This note analyzes why the first SymAFL-v1 real-world runs showed very low
PCBT rejection rates for XZ/liblzma and libxml2, and whether PCBT-admitted
candidates produced coverage gains and entered the AFL queue.

## Short answer

No. In the original runs, PCBT-admitted candidates did **not** all produce
coverage gains or enter the queue.

- **XZ/liblzma:** PCBT exhausted approximately two seconds into fuzzing. At
  most one mutated candidate from the active PCBT phase entered the queue; the
  final corpus growth to 158 entries happened mostly **after** PCBT had already
  exited.
- **libxml2:** 7,403 candidates were admitted, but AFL recorded 7,400 timeouts
  and **zero** new queue entries. The two queue files are only the original
  seeds.

The dominant artifact was AFL timeout auto-scaling. The runner used
`-t 2000+`; the `+` allowed AFL to reduce the timeout from concrete dry-run
calibration to 5–7 ms. Admitted concolic executions often need much longer
than that, so they were killed before producing useful coverage or a `.pct`
trace. Timeouts are deliberately not counted as clean no-coverage-gain
feedback, so those branches were not pruned either.

## Original 60-second runs

| Target | Admitted | AFL timeouts | Trace inserts | No-gain events | Final corpus | New corpus entries | Variable entries | Last find |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| XZ/liblzma | 255 | 261 | 2 | 0 | 158 | 156 | 0 | non-zero |
| libxml2 | 7,403 | 7,400 | 2 | 0 | 2 | 0 | 0 | 0 |

Interpretation:

- XZ's `trace_insert_cnt=2` does not mean that all 255 admitted candidates
  gained coverage. The PCBT tree is tiny and the run reached `CheckInput=-2`
  very early; subsequent queue growth used ordinary AFL executions after
  `symcc_mode` was disabled.
- libxml2's `corpus_found=0` and `last_find=0` are direct evidence that none
  of the admitted candidates produced a retained coverage gain in that run.
- In both runs, `pcbt_no_cov_gain_cnt=0` is not evidence of universal success;
  it mostly means the executions timed out before a clean coverage verdict.

## Fixed-timeout diagnostic runs

The diagnostic used the same binaries and seeds but replaced `-t 2000+` with
fixed `-t 2000` and ran for 30 seconds.

| Target | Candidates | Admitted | Rejected | No-gain events | Saturated branches | New queue entries | Variable entries | Timeouts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| XZ/liblzma | 65 | 59 | 6 (9.23%) | 21 | 0 | 30 | 30 | 5 |
| libxml2 | 1,063 | 938 | 125 (11.76%) | 873 | 2 | 62 | 62 | 0 |

These runs confirm the timeout artifact:

- With 2000 ms available, libxml2 stopped timing out and produced 873 clean
  no-gain feedback events. Its rejection rate rose from 0.26% to 11.76%.
- XZ now recorded 21 clean no-gain events and 30 queue-gaining entries.
- libxml2 produced 62 queue-gaining entries, but 873 admitted candidates still
  did not gain coverage. Thus the low rejection rate is not caused by universal
  coverage success.

## Second issue: coverage-gaining entries are marked variable

In both fixed-timeout diagnostics, every newly queued entry was marked
variable:

- XZ: `corpus_found=30`, `corpus_variable=30`
- libxml2: `corpus_found=62`, `corpus_variable=62`

The current `save_if_interesting()` logic inserts a `.pct` trace only when the
queue entry is neither calibration-failed nor variable. Therefore:

- candidates did enter the AFL queue in the fixed-timeout diagnostics;
- but their traces were not inserted into the PCBT;
- the PCBT did not learn from those successful paths;
- similar candidates can be admitted repeatedly, further depressing the
  rejection rate.

This is likely caused by measuring the first coverage signal in concolic mode
and then calibrating/re-executing in concrete mode. The two modes can produce
different coverage behavior, so AFL marks the entries as variable even though
the first concolic execution produced a real input and a usable `.pct` trace.

## Why rejection remains low after fixing the timeout

### XZ/liblzma

- The final PCBT is extremely small: the original final tree contains only the
  root, a true leaf, and a false leaf.
- The initial corpus quickly exhausts the small tree. The original run exited
  PCBT after roughly two seconds.
- A small tree cannot reject many candidates; the important phase separation
  is therefore PCBT-active versus post-exhaustion ordinary AFL.

### libxml2

- The initial seeds generate a broad PCBT; the final DOT file has 1,158 lines.
- Many byte mutations can satisfy some unexplored symbolic branch, so
  `CheckInput()` admits most candidates.
- The fixed-timeout run had 873 no-gain events, but those failures were spread
  across many branches. Only two branches reached the default
  `MAX_ALLOWED_RIGHT_CHILD_CNT=128` threshold.

## Recommended follow-up changes

1. **Use a fixed timeout for PCBT campaigns.** The runner default has been
   changed from `2000+` to `2000`; future PCBT-ON and PCBT-OFF runs use the
   same fixed policy.
2. **Add explicit PCBT outcome counters.** Current aggregate counters cannot
   distinguish clean no-gain, timeout, variable gain, stable queue gain, and
   skipped insertion. Add at least:
   - `pcbt_timeout_cnt`
   - `pcbt_clean_no_cov_gain_cnt`
   - `pcbt_queue_gain_cnt`
   - `pcbt_variable_gain_cnt`
   - `pcbt_insert_skipped_variable_cnt`
3. **Revisit the `var_behavior` guard around `InsertTrace()`.** For SymAFL-v1,
   the first concolic execution already provides the concrete input and its
   `.pct` trace. If AFL accepts the coverage gain, skipping PCBT insertion
   merely because calibration is variable prevents the tree from learning.
4. **Consider a separate timeout-feedback policy.** Timeouts should not be
   equated with clean no-gain executions, but branches that repeatedly time
   out may need their own threshold or a larger concolic timeout.
5. **Report PCBT-active and post-exhaustion phases separately.** XZ makes
   this especially important: most final queue growth happened after PCBT had
   already disabled itself.

## Evidence locations

- Original XZ output: `/tmp/symafl-realworld/xz-20260727-023501/xz`
- Original libxml2 output: `/tmp/symafl-realworld/libxml2-20260727-031757/libxml2`
- Fixed-timeout diagnostics: `results/throughput/diagnostics/`
- Raw diagnostic AFL output: `/tmp/symafl-realworld/*-fixed-timeout-diag/`
