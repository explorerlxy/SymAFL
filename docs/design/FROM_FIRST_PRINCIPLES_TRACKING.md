# From First Principles: The Lightest Possible Symbolic Tracking

Date: 2026-07-28 (rewritten same day: refocused on tracking cost proper)
Status: design exploration. Scope: **making the tracked execution itself
faster and lighter** — per-op tracking cost, tracking state, and encoding
construction cost. Frequency gating (screening/replay economics) is settled
elsewhere (v1 contract, P3) and is explicitly out of scope here.

## 1. The cost equation of a tracked execution

A tracked run's overhead decomposes into exactly three per-instruction
terms:

```
T_run = Σ_tainted-ops [ C_carry   // forward-carry of tracking state per op
                      + C_access  // reading/writing that state (shadow/TLS)
                      + C_record  // making the information recoverable later
                      ]
      + C_space                   // memory footprint of state + records
```

Everything an engine does is a choice of what to carry (C_carry), where it
lives (C_access), and what is written down (C_record). Comparing the three
existing points in the design space on these terms:

| Engine | Carries per value | Per-op mechanics | Est. insns/op |
|---|---|---|---|
| SymCC (QSYM backend) | 64-bit `Expr*` into heap DAG | runtime call `_sym_build_*` + null checks + 1024-FIFO hash-cons lookup + `shared_ptr` copies + `std::map` liveness insert (O(log n)) | ~100+ |
| SymSan | 32-bit label into AST table | `__taint_union` call + Merkle hash + dedup hash-table lookup + array append | ~50–80 |
| **Floor reference: boolean taint (DFSan)** | 1 taint bit | 2 shadow loads + OR + 1 shadow store, all inlined | ~5–8 |

## 2. First-principles observation: expressions are not tracking state

The tracked run's job is to make predicates *recoverable*, not to *have*
them. A predicate instance is fully determined by:

1. the **static slice** of the branch condition (compile-time, free);
2. which values are input-derived (**taint**, 1 bit);
3. the **concrete values of untainted operands** (fold to constant leaves);
4. **input offsets at load sites** (concrete address − input base);
5. the **def-use links** between dynamic value instances.

Corollary 1: **untainted instructions never need records** — an untainted
operand is a constant leaf equal to its concrete value.

Corollary 2: the forward state per value does not need to be an expression
or even a label — it only needs to answer two questions: *is this value
input-derived?* and *if so, which record produced it?* Both fit in one u32:

> **shadow slot = u32 trace index; 0 = untainted, k>0 = produced by trace
> record #k.** Taint flag and producer link are the same word.

This is the same 4 B/byte footprint as SymSan's labels, but it carries a
*link into a sequential record stream* instead of an AST node — and building
it requires no hashing, no allocation, no calls.

## 3. The lazy design (lightest tracked run in this design family)

### 3.1 Compile time (once per build)

- DFSan-style **inline** instrumentation — tracking logic emitted as IR,
  zero runtime calls (SymCC's per-op `_sym_build_*` call overhead and
  SymSan's `__taint_union` call are both eliminated at the source).
- Every value gets a shadow slot (register shadows as compile-time SSA
  variables, memory via direct-mapped shadow, ASan-style
  `shadow = (addr & mask) << 2`, 4 B/byte, O(1)).
- Static **taint-influence analysis**: instructions that provably can never
  depend on input (functions unreachable from input reads) are not
  instrumented at all. Optional **branch-slice restriction**: only record
  ops in the static backward-slice union of conditional branches.
- Input-source wrappers (`read/fread/memcpy/...`) define offset bases and
  propagate shadow indices across copies.

### 3.2 Per tainted op (the entire in-run cost)

```
c1 = shadow[op1]; c2 = shadow[op2]        // 2 loads (reg shadows often free)
if ((c1 | c2) == 0) { shadow[d] = 0; }    // both concrete: nothing else
else {
  trace[i] = {site_id, c1, c2, v1, v2}    // sequential append, ~16–28 B
  shadow[d] = i++                          // 1 store
}
```

~10–15 instructions, no calls, no hashing, no allocation, branch highly
predictable (taint density is phase-stable). Concrete operand values
(`v1/v2`) are recorded only when the corresponding index is 0 — they are the
future constant leaves. Wide memory ops use word-granularity shadow with
byte refinement on demand; input-range loads record `(offset, len)` —
the uload fusion happens *at the source*.

Branch events append `{site_id, taken, cond_index}` (12 B). Nothing else is
written anywhere: no dedup, no hash-cons, no simplify, no serialization
logic. **Run-time dedup is deliberately omitted** — it exists in eager
engines to bound expression memory and buy pointer identity; a sequential
trace needs neither (memory is bounded by execution length; identity is the
record index).

### 3.3 After the run (not in the tracked path)

One backward pass per branch event: DFS from `cond_index` over the record
stream; `index 0` operand → constant leaf from its recorded value;
input-range load → `(offset, len)` leaf; emit post-order nodes into the
interned arena (Merkle hash-cons happens here, once per unique structure,
not per dynamic op). Within-run cone sharing across branches via a
`record_idx → arena_node` memo. Cost ∝ Σ consumed cone sizes — the
information-theoretic minimum for materializing predicates.

## 4. Budget comparison (per tainted op and per run)

| Design | insns/tainted-op | calls | hashing | alloc | Tracked-run overhead (est.) |
|---|---|---|---|---|---|
| SymCC eager | ~100+ | 1–2 | FIFO + map | heap + refcount | 5–30× native (measured, pre-P1 more) |
| SymSan eager | ~50–80 | 1 | Merkle + dedup | array bump | 9.2× geomean (paper, NS) |
| **Lazy trace (this design)** | **~10–15** | **0** | **0** | **0** | **≈ taint + append ≈ 1.5–2.5× native** |
| Pure boolean taint (floor) | 5–8 | 0 | 0 | 0 | 1.2–1.5× native (DFSan class) |

The gap between this design and the pure-taint floor is exactly the record
append (~5–8 stores) — the cheapest possible form of persistence (sequential,
write-only, cache-friendly, prefetchable).

## 5. Space costs

- Shadow: 4 B/byte direct-mapped (same as SymSan; u32 index doubles as
  taint flag, so no separate taint bitmap).
- Trace: ~16–28 B per tainted op, sequential, lifetime = one execution.
  Mitigations for extreme runs (xz-class: millions of tainted ops):
  slice restriction (§3.1), site-delta varint encoding (~40% smaller),
  ring buffer with overflow flag → run marked uninsertable (same semantics
  as today's `.pct` overflow).
- Arena (post-run): bounded by unique interned structure, per the v2 design.

## 6. The floor argument

Within the "instrument and track forward" family, the physical floor is
DFSan-level boolean taint (~1.2–1.5× native) — anything less loses the
information needed to recover predicates (re-execution/hardware-trace
routes leave this family and buy their costs back as determinism
requirements and decoders). The lazy design sits ~1.3–1.7× above that
floor, the delta being the record append — i.e., it is within ~2× of the
absolute floor of its family, while eager designs sit 6–20× above it
because they pay expression construction per dynamic op instead of per
unique consumed cone.

## 7. Risks specific to going lazy

| Risk | Note |
|---|---|
| Memory versioning bugs (store→load links) | shadow last-writer invariant; sequential execution makes register links exact by SSA discipline |
| Taint loss (asm, uninstrumented libs, fp/vector) | index-0 fallback = constant leaf → predicate under-approximation; must be *flagged* opaque, conservative at screening; same failure class as all eager engines' uninstrumented code |
| Reconstruction correctness | differential validation: same seeds through lazy and eager producers, require identical predicate semantics (BV corner-case suite) |
| Trace overflow | ring cap + flag; worst case = run cannot be inserted |
| Multi-threading | out of scope (single-threaded harnesses, as today) |

## 8. Relationship to v2/v3 (one paragraph)

The consumer side (arena, post-order interned encoding, VM/prefix-cache/
JIT) is unchanged — this design only swaps the *producer*: v2 ships with
the eager SymCC DAG builder serializing into the arena (trivially correct,
already built); the lazy producer (§3) replaces it when tracked-run cost
justifies the engineering. Encoding (16B post-order nodes, uload leaves,
Merkle interning, symVars ranges) is shared by both producers verbatim.
