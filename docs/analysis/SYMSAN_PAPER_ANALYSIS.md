# SymSan Paper Analysis — and the "Replace SymCC?" Question for SymAFL

Date: 2026-07-28
Paper: *SymSan: Time and Space Efficient Concolic Execution via Dynamic
Data-flow Analysis* (USENIX Security 2022, Ju Chen et al., UC Riverside /
KAIST / SNU). Local copy:
`papers/references/2022-USENIX-Security-SYMSAN_Time_and_Space_Efficient_Concolic_Execution_via_Dynamic_Data-flow_Analysis.pdf`
Status: analysis; verdict — **do not replace SymCC; adopt four techniques into v2**.

## 1. Core insight

A concolic executor's work per instruction (`d = a ⊕ b`) decomposes into four
steps: parse the instruction, **locate** operand expressions, **create** a new
expression, **update** the symbolic state σ. The paper's claim: after
compile-time instrumentation killed the "parse" cost (QSYM/SymCC), the
remaining bottleneck is locate/create/update — i.e. *symbolic-state
management* — and forward symbolic execution is exactly a **dynamic data-flow
analysis** whose labels are symbolic expressions. Therefore: build the
concolic executor on top of LLVM's **DataFlowSanitizer (DFSan)** and inherit
two decades of label-tracking optimization for free.

Motivating measurements (their §2.3): SymCC spends ≥65% of execution time on
objdump maintaining allocated AST nodes; the address→expression lookup
structure alone holds 98 MB for one objdump instance; SymCC/SymQEMU impose
8.5×–32,220× / 226.9×–39,658.8× overhead vs native on 24 real-world apps.

## 2. Architecture and flow

```
LLVM IR ──► instrumentation pass (DFSan + operator metadata) ──► codegen
                │ instrumented binary + SymSan runtime
                ▼
   native exec ─► labels flow (TLS / shadow mem / shadow vars)
                ▼
   branch/switch sink ─► AST forest ─► SMT serializer ─► solver ─► new inputs
```

For each instrumented instruction (running example: `%4 = mul %3, %1`):

1. **Load**: fetch operand labels — from TLS (`__dfsan_arg_tls`) for args,
   from shadow memory for memory-loaded values (ASan-style address
   translation), from shadow *variables* for locals.
2. **Creation**: one runtime call
   `__taint_union(l1, l2, OP, size1, size2, concrete1, concrete2)` —
   operator and operand widths are *compile-time constants* baked into the
   call; concrete operand values travel inline.
3. **Store**: bind the new label to the destination's shadow variable /
   shadow memory; return-value label via `__dfsan_retval_tls`.

Label checking happens at `br`/`switch` sinks (coverage-oriented); nested
branches handled QSYM-style (precedent branches with overlapping input
bytes); symbolic addresses same strategy as QSYM/SymCC.

## 3. The four mechanisms that make it fast

### 3.1 Expression representation: 32-bit labels + AST table
- A symbolic expression is a **32-bit label** = index into a global AST
  table (array), not a 64-bit pointer to a heap AST node (SymCC/QSYM).
- AST node (their Fig 3), packed:
  `{label l1, l2; u64 op1, op2; u16 op; u16 size; u32 hash}` —
  children are labels; **label 0 ⇒ concrete child**, whose value sits inline
  in `op1/op2`. This is structurally identical to our v2
  `Node{opcode, kind, bits, child1, child2, aux}` — convergent design.
- Allocation: **forward allocation** on a reserved array via one
  `atomic_fetch_add` — no heap, no refcounting, no GC. Justification:
  hybrid-fuzzing executions are short (<1 s) and inputs small; leaks don't
  matter. (SymCC in contrast: ~3% allocating + ~28% tracking AST nodes via
  `shared_ptr`/Z3 refcounting — their profiling, §3.3.)

### 3.2 O(1) direct-mapped shadow memory
- ASan-family mapping: `shadow_for(addr) = (addr & ShadowMask) << 2` —
  one 4-byte label per application byte, constant time, no page table walk.
- SymCC (and our tree) instead: `std::map<uintptr_t, SymExpr*>
  g_shadow_pages` — O(log n) per page lookup, 8-byte pointers per byte.
- Memory layout is fixed via a **custom linker script** (application,
  shadow, AST table, hash table in reserved regions; 64-bit only).

### 3.3 Label passing: TLS + shadow variables
- Args/returns through per-thread TLS — a single `mov` on x86.
- Locals use compile-time-introduced shadow variables (same trick as
  SymCC's IR-level shadow SSA values — no runtime lookup for registers).
- libc handled by wrapper functions with the DFSan ABI (extra label args).

### 3.4 Dedup + load/store simplification
- **Merkle-tree hash**: every node stores a hash (leaf = label; internal =
  hash of children); identity check compares hash first, then fields.
  Reverse hash table maps nodes → existing labels (lock-free chaining).
- **`uload` operator**: `label := (uload, l_start, size, size)` represents
  loading *a consecutive sequence of input bytes* as ONE node, replacing
  the concat-of-bytes tree (a 4-byte load otherwise costs 3 concat nodes;
  each store costs 4 extract nodes). Measured `uload:concat` ratio 13.8:1.
  Store of a `uload`-derived label extracts byte labels directly.
- Ablation (Appendix): dedup +16%, load/store simplification +6%.

### 3.5 Library wrappers
- Label introduction on `read/fread/pread/getc/...`: input file size known
  at open, label range pre-reserved, offsets assigned per read.
- `fmemcmp` higher-order operator: symbolizes `memcmp` return as one node
  ("bytes of buf1 equal bytes of buf2") instead of per-byte comparisons.

## 4. Evaluation numbers that matter for us

| Setting | SymSan | SymCC | Note |
|---|---|---|---|
| Pure concrete (nbench mem/int/fp idx) | 12.9× / 20.5× / 8.35× | 254.8× / 65× / 65× | instrumentation-only cost |
| Pure taint, CGC avg (median) | 1.3× (1.8×) | 4.9× (127.1×) | shadow + label passing only |
| Pure taint, real-world avg (median) | 3.7× (2.25×) | 18× (4.5×) | |
| **Concolic, NO solving, real-world geomean** | **9.2×** | **589.2×** | **62.0× speedup** |
| Concolic, no solving, CGC avg | 1.36× | 5.3× | SymSan-QSYM-backend 1.37× |
| Memory (avg peak RSS) | 14.1 MB | 337.9 MB | native 4.1 MB |
| Constraints processed / solved | 15.86 M / 31.67% | 7.10 M / 32.30% | faster collection ⇒ 2× more solving |
| Fuzzbench | 1st avg score, 3rd avg rank | 6th / 5th | |

Their evaluation methodology is a good template: overhead split into
**instrumentation / symbolic-state access / symbolic-state management /
solving**, with Taint / NS / full configurations isolating each.

## 5. Calibration against SymAFL's own measurements

Critical: their SymCC-NS baseline ≈ **our pre-P1 state**. Their SymCC-NS
still pays per-branch `to_string` dedup (our measured 82.7% on xz) plus
QSYM-backend AST management — exactly what P1 (ast_id dedup) + P2 (opt-in
simplify) + P3 (lazy trace/dump) removed. Post-P1–P3, our concolic runs:

- xz standalone: 0.09 s vs 21.4 ms concrete ≈ **4.2×**;
- libxml2: ≈ 1.1–2.2× concrete;
- inherent tracking (DAG build + shadow + notify + register map): **1–6% of
  concolic CPU**.

So on the no-solving metric we are already at or beyond SymSan-NS's 9.2×
geomean for our target class. SymSan's remaining wins all live **inside our
1–6% tracking bucket**:

| SymSan mechanism | Our current equivalent | Est. gain if adopted |
|---|---|---|
| direct-mapped O(1) shadow | `std::map` page table, 8 B/byte | per-access log n → O(1), half the shadow traffic (4 B labels) |
| array + forward alloc | `shared_ptr` + `allocatedExpressions` std::map + 1024-FIFO hash-cons | removes O(log n) register + refcount churn |
| `uload` fusion | concat-of-bytes trees from per-byte shadow | few× fewer nodes on memory-derived values |
| Merkle-hash dedup | pointer-identity per run | enables cheap *cross-run* interning |

Aggregate realistic effect on SymAFL concolic time: **low single-digit
percent** on xz/libxml2-class targets. Better memory locality may matter
more on extreme-trace targets (xz's 21.8 MB trace), but the v2 recorder
removes per-op runtime objects there anyway.

## 6. What replacing SymCC would actually cost

1. **Pass-pipeline position** — SymAFL's vuln→path binding requires
   instrumentation to run *after* RSan SafeStack inside the LTO CodeGen
   pipeline. SymSan is an IR-level sanitizer with its own ABI (TLS
   conventions, runtime ctors, interface wrappers); porting it to the
   post-SafeStack CodeGen slot is a rewrite of its instrumentation driver.
2. **Address-space ownership conflict** — SymSan demands fixed regions
   (shadow at `0x200000000…`, AST table at `0x400010000000…`) via its own
   linker script; RSan already owns the layout (custom `$RSAN_LDS`,
   `pld.so`, TCMalloc, SafeStack regions). Two address-space owners; merging
   is deep surgery in both.
3. **Runtime contract port** — forkserver, 6 SHM channels, `*__symbolic`
   mode switch (`inputFileDescriptor` duality), RSan `int3` crash capture,
   dump gating: all exist only in our QSYM backend; none in SymSan.
4. **Loss of accumulated fixes** — P1–P6 (ast_id dedup, opt-in simplify,
   lazy trace + dump SHM, CallStackManager, funnel-shift P6, vector
   bitcast), plus our documented understanding of the QSYM runtime.
5. **Maintenance risk** — 2022 research prototype, older LLVM/DFSan
   generation, no active maintenance.
6. Neutral: no fp/vector/intrinsics — same limitation as our current setup
   (opaque fallback).

## 7. Verdict and what we adopt

**Do not replace SymCC.** The replacement targets a bucket we measured at
1–6%, at the price of re-integrating with RSan's pipeline position and
address-space layout, re-implementing the AFL/SHM runtime contract, and
discarding working fixes. The paper's own numbers show the battle it wins
(Symbolic-state management) is one we already won differently (P1–P3 + v2's
solver-free design).

**Adopt into the v2 recorder/arena (cheap, paper-validated):**

1. **`uload` ⇒ our `(offset, len)` fused leaf** — already planned as
   "consecutive byte-read fusion"; the paper validates both its ubiquity
   (13.8:1 over concat) and its effect (+6%).
2. **Merkle-hash interning** — adopt hash-per-node for the arena's
   cross-run structural interning; gives O(1) predicate identity for free
   (also usable by the prefix cache and tree dedup).
3. **Array + stable 32-bit indices, inline concrete children** — confirms
   our arena-offset / `aux`-field design; no action needed beyond keeping it.
4. **`fmemcmp` higher-order operator** — future addition to the
   interceptor family: single-node encoding of memcmp-style magic-byte
   checks (common in parsers; composes with RSan's per-call-site
   interception).

**What SymSan is NOT**: it is still *eager* — every symbolic instruction
pays a `__taint_union`. The "reconstruct predicates lazily at branch points
from a lightweight dependence trace" idea (our possible v3) remains
unexplored by this paper; SymSan strengthens, rather than closes, that
research gap.

**Positioning for the MDPI paper**: SymSan optimizes symbolic-state
management to *collect and solve* constraints faster; SymAFL removes the
solver from the loop entirely and shows screening needs only provenance
tracking + native evaluation. Cite it as the strongest sibling baseline;
borrow its four-way overhead decomposition (instrumentation / state access /
state management / solving) for our evaluation section.
