# Sliced-Target inputcheck(): Screening with the Target's Own Instructions

Date: 2026-07-28
Status: design exploration (user's proposal, analyzed; v3 architecture candidate)
Question: instead of tracing tainted instructions and encoding predicates,
compose the input-dependent instructions of the target itself into an
`inputcheck()` function — a "slimmed target" that performs seed screening.

## 1. The idea, made precise (three levels)

**L1 — inputcheck() as tree-composed native predicate code.**
Each PCBT node's predicate is not an encoded DAG but the *original
instruction sequence* that computed the branch condition, lifted out of the
target and composed into the tree's if-else skeleton. Frontier stubs and
monotonic ret→jmp hot-patching carry over unchanged; the "eval blocks"
become lifted slice fragments.

**L2 — the closure is a backward slice, not bare tainted instructions.**
"Tainted instructions only" is not closed under data dependence: an
untainted instruction (`size = hdr_len * 4`) whose output feeds the tainted
cone (`buf[size + in[0]]`) must be kept, or the sliced values are wrong.
What remains = the **backward slice of all input-derived branch conditions
w.r.t. the input** — producers included, everything else (output,
formatting, non-input logic) deleted. The slice ratio (measured on real
parsers: typically 30–70% of instructions survive, not a tiny residue) is
the number that decides the whole value proposition.

**L3 — the extreme corollary: dynamic symbolic tracking disappears.**
If predicate semantics are recovered *statically* from the binary via
slicing, the runtime never needs to build or ship expressions. The target
only records **which way each slice-relevant branch went** `(site, taken)`
— a branch log. The set of slice-relevant branches is a static
over-approximation (branch's backward slice reaches an input read), so not
even runtime taint is required. Tracking cost collapses to AFL-class branch
logging; InsertTrace consumes the branch log; crash binding reads the log
prefix. **Maximal laziness: record almost nothing, re-derive everything at
screening time.** Boundary concrete values (the lazy-trace design's `v1/v2`
fields) need no recording either — the closed slice *recomputes* them
deterministically.

## 2. What this kills (the case for)

1. **The entire encoding layer and its risk surface.** No DAG
   serialization, no arena/interning, no VM BV-corner-case semantics
   (div-by-zero defined values, shift ≥ width, width masks), no opaque
   nodes, no fp/vector exclusions. The evaluator *is* the original code —
   screening verdict ≡ execution verdict **by construction**. This removes
   the single biggest correctness risk of the v2 design.
2. **The trace-size explosion on state-accruing loops.** The DAG of a
   loop-carried predicate is the loop *unrolled* (XZ's 21.8 MB `.pct`);
   the slice keeps the loop **rolled** — O(loop body) code, same iteration
   time. The type-2 "accrued symbolic state" blowup from the loop
   discussion simply does not exist in this representation.
3. **The recorder.** InsertTrace's input shrinks from "predicate DAG
   sequence" to "branch event sequence"; SHM traffic per run ~ a few KB.
4. **Early-exit economics preserved.** Interleave slice execution with the
   tree walk: stop at the first frontier (admit) or saturated subtree
   (reject). Rejected candidates pay only the shared-prefix computation —
   same early-exit shape as prefix-cached DAG walking.
5. **Hot-patching carries over.** Frontier stub → `jmp` to newly linked
   slice-fragment chain; append-only code arena; three monotonic patch
   types unchanged.

## 3. The four hard problems (the case against / the real costs)

1. **Path-specific state threading.** Node N's condition must be evaluated
   in the state produced by *its unique root-to-N path*. The composed
   function threads live registers + memory along tree paths; a loop spine
   of depth k is the loop-body fragment linked k times (the tree *is* the
   unrolling — structurally fine, but code and state grow along deep
   spines).
2. **Cross-candidate sharing is expensive.** The DAG design shares
   computation across candidates for free (interning + per-candidate value
   memoization + prefix verdict cache: cost ∝ changed region). The slice
   re-executes the prefix per candidate (cost ∝ prefix length) unless we
   checkpoint program state at tree nodes — and a checkpoint is live
   registers + dirty memory (potentially MBs), versus the DAG cache's
   per-node verdict bits. **For deep-shared-prefix workloads (AFL mutants),
   this is the slice design's structural tax.**
3. **Construction machinery is heavy.** Executable slicing at IR level
   (interprocedural, pointer-analysis-driven — "executable slices" are
   notoriously hard to make actually runnable), per-insert slice-fragment
   extraction/linking, a private data arena for the slice's memory
   (constant tables embedded; `malloc` → bump allocator; syscalls excised
   or the target is disqualified), and **sandboxing**: the slice contains
   the program's own vulnerable logic, and a crafted candidate can drive it
   into UB *inside the fuzzer process* — needs SFI-style isolation or a
   helper process.
4. **Purity qualification.** The slice must be a deterministic pure
   function of the input (no I/O, no allocation nondeterminism, no
   uninitialized reads). Parsers qualify; stateful/protocol targets may
   not. Slice *soundness* (no missed producer) replaces the VM's BV
   semantics as the correctness risk — over-approximating pointer analysis
   keeps it sound at the cost of slice size.

## 4. Economics: when each representation wins

| Workload shape | Winner | Why |
|---|---|---|
| Loop/state-accruing predicates (XZ checksums, compressed formats) | **slice** | rolled loops; no unrolled-DAG explosion |
| fp/vector-heavy, or exotic semantics | **slice** | native execution, zero re-implementation |
| Deep shared prefixes × huge candidate volumes (AFL mutants) | **DAG** | interning + value memoization + prefix cache give O(changed region); slice pays O(prefix) per candidate |
| Small arithmetic predicates (magic-byte parsers) | **DAG** | VM ops ≈ slice instructions, but sharing wins |
| Unacceptable semantics-drift risk | **slice** | verdict ≡ execution by construction |

**Hybrid option**: keep the DAG encoding and add a `CALL_SLICE` opcode —
arithmetic cones evaluate in the VM; loop-carried cones call a lifted loop
fragment. Each representation covers the other's worst case.

## 5. Prior art (and what is novel here)

- **Jigsaw** (Ju Chen et al., S&P 2022 — SymSan's first author):
  synthesizes *per-branch constraint functions* as standalone compilable
  code for native solving — validates that lifted per-branch slices are
  buildable and fast. The present idea = Jigsaw tree-composed into a
  whole-program slice **plus** replacing the symbolic trace with a pure
  branch log (L3). That combination appears to be novel.
- **Chopper** (chopped symbolic execution): skip irrelevant code during
  symbolic execution — same slicing instinct, different consumer.
- Partial evaluation / program specialization: inputcheck() is literally
  the target specialized w.r.t. everything except the input, restricted to
  tree paths.
- Redqueen/Eclipser: the same "lightweight instead of symbolic" philosophy
  with weaker mechanisms (operand correspondence / linear approximation).

## 6. Decision procedure (proposed next measurement)

Before committing engineering: **measure the slice ratio and shape on the
two pole targets** — xz (loop-heavy, trace-exploding; slice should win) and
libxml2 (shallow magic-byte parsing, huge candidate volume; DAG should
win). A static LLVM prototype: compute the backward-slice union of all
input-reaching conditional branches, report (a) surviving instruction
fraction, (b) fraction containing loops/syscalls/allocation, (c) live-state
size at branch points (checkpoint cost). If xz's slice is small and loopy,
the sliced-inputcheck() becomes the v3 producer; if slices are large and
memory-heavy, the DAG+arena design stands and the slice idea survives only
as the `CALL_SLICE` hybrid for loop cones.
