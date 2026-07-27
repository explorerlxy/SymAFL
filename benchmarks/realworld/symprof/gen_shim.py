#!/usr/bin/env python3
"""Generate an LD_PRELOAD interposition shim that times every _sym_* runtime
call and (in aggregate) every Z3 C API call, using rdtsc.

Wrapper ABI notes:
- Only functions with <= 6 integer/pointer args are wrapped (no stack args).
- Double args (xmm0-7) are saved/restored across the timing prologue.
- All wrapped functions return void/int/pointer in rax (true for _sym_* and
  the Z3 C API).
"""
import re
import subprocess
import sys

RT = "/media/hahafish/Data/ForUbuntu/SymAFL/symcc/qsym64build/libsymcc-rt.so"
Z3 = "/lib/x86_64-linux-gnu/libz3.so.4"
OUT_S = "/tmp/symprof/shim.s"
OUT_C = "/tmp/symprof/shim.c"


def exports(lib, pattern):
    out = subprocess.run(["nm", "-D", "--defined-only", lib],
                         capture_output=True, text=True, check=True).stdout
    names = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "T" and re.fullmatch(pattern, parts[2]):
            names.append(parts[2])
    return sorted(set(names))


def z3_arg_counts(header_paths):
    """Parse Z3 C API headers for function arg counts."""
    text = ""
    for p in header_paths:
        try:
            with open(p) as f:
                text += f.read() + "\n"
        except FileNotFoundError:
            pass
    # strip comments
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//.*", "", text)
    counts = {}
    # prototypes look like: RET Z3_API NAME(ARGS);
    for m in re.finditer(r"Z3_API\s+(Z3_\w+)\s*\((.*?)\)\s*;", text, re.S):
        name, args = m.group(1), m.group(2)
        args = args.strip()
        if not args or args == "void":
            counts[name] = 0
        else:
            # count top-level commas
            depth = 0
            n = 1
            for ch in args:
                if ch in "([":
                    depth += 1
                elif ch in ")]":
                    depth -= 1
                elif ch == "," and depth == 0:
                    n += 1
            counts[name] = n
    return counts


sym_names = exports(RT, r"_sym_\w+")
z3_names = exports(Z3, r"Z3_\w+")
argc = z3_arg_counts([
    "/usr/include/z3_api.h",
    "/usr/include/z3_algebraic.h",
    "/usr/include/z3_rcf.h",
    "/usr/include/z3_fpa.h",
    "/usr/include/z3_polynomial.h",
    "/usr/include/z3_ast_containers.h",
    "/usr/include/z3_fixedpoint.h",
    "/usr/include/z3_optimization.h",
    "/usr/include/z3_spacer.h",
    "/usr/include/z3_v1.h",
])

z3_wrapped = [n for n in z3_names if argc.get(n, 99) <= 6]
z3_skipped = [n for n in z3_names if n not in z3_wrapped]

# sanity: every _sym_ function has <= 6 args by design of the runtime ABI
ASM_MACRO = r"""
.macro WRAPFN name, slotp, realp
  .globl \name
  .type \name,@function
\name:
  push %rbp
  mov %rsp,%rbp
  push %rbx
  push %r12
  push %r13
  push %r9
  push %r8
  push %rcx
  push %rdx
  push %rsi
  push %rdi
  sub $136,%rsp
  movups %xmm0,0(%rsp)
  movups %xmm1,16(%rsp)
  movups %xmm2,32(%rsp)
  movups %xmm3,48(%rsp)
  movups %xmm4,64(%rsp)
  movups %xmm5,80(%rsp)
  movups %xmm6,96(%rsp)
  movups %xmm7,112(%rsp)
  rdtsc
  shl $32,%rdx
  or %rdx,%rax
  mov %rax,%r13
  movups 0(%rsp),%xmm0
  movups 16(%rsp),%xmm1
  movups 32(%rsp),%xmm2
  movups 48(%rsp),%xmm3
  movups 64(%rsp),%xmm4
  movups 80(%rsp),%xmm5
  movups 96(%rsp),%xmm6
  movups 112(%rsp),%xmm7
  add $136,%rsp
  pop %rdi
  pop %rsi
  pop %rdx
  pop %rcx
  pop %r8
  pop %r9
  sub $8,%rsp
  call *\realp(%rip)
  add $8,%rsp
  mov %rax,%r12
  rdtsc
  shl $32,%rdx
  or %rdx,%rax
  sub %r13,%rax
  lea \slotp(%rip),%rcx
  addq $1,0(%rcx)
  addq %rax,8(%rcx)
  mov %r12,%rax
  pop %r13
  pop %r12
  pop %rbx
  pop %rbp
  ret
.endm
"""

asm = [".text", ASM_MACRO]
data = [".data", ".align 8"]
centries = []

all_wrapped = [("sym", n) for n in sym_names] + [("z3", n) for n in z3_wrapped]
for kind, name in all_wrapped:
    lbl = name.replace(".", "_")
    slot = f"slot_{lbl}"
    real = f"real_{lbl}"
    asm.append(f"WRAPFN {name}, {slot}, {real}")
    data.append(f".globl {slot}\n.hidden {slot}\n{slot}: .quad 0,0")
    data.append(f".globl {real}\n.hidden {real}\n{real}: .quad 0")
    centries.append((kind, name, slot, real))

c = []
c.append(r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>

struct ent { const char *kind; const char *name; unsigned long *slot; void **real; };
""")

for kind, name, slot, real in centries:
    c.append(f'extern unsigned long {slot}[2]; extern void *{real};')
c.append("static struct ent ents[] = {")
for kind, name, slot, real in centries:
    c.append(f'  {{"{kind}", "{name}", {slot}, &{real}}},')
c.append("};\n")

c.append(r"""
static double g_tsc_hz;

__attribute__((constructor(101)))
static void symprof_init(void) {
  for (unsigned long i = 0; i < sizeof(ents)/sizeof(ents[0]); i++) {
    void *p = dlsym(RTLD_NEXT, ents[i].name);
    if (p) *ents[i].real = p;
  }
  struct timespec a, b;
  unsigned long long t0, t1, d;
  clock_gettime(CLOCK_MONOTONIC, &a);
  __asm__ volatile("rdtsc; shl $32,%%rdx; or %%rdx,%%rax" : "=a"(t0) :: "rdx");
  do { clock_gettime(CLOCK_MONOTONIC, &b); }
  while ((b.tv_sec - a.tv_sec) * 1000000000.0 + (b.tv_nsec - a.tv_nsec) < 20000000.0);
  __asm__ volatile("rdtsc; shl $32,%%rdx; or %%rdx,%%rax" : "=a"(t1) :: "rdx");
  d = t1 - t0;
  double ns = (b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec);
  g_tsc_hz = d / (ns / 1e9);
}

__attribute__((destructor))
static void symprof_fini(void) {
  FILE *f = stderr;
  const char *path = getenv("SYMPROF_OUT");
  if (path) {
    FILE *g = fopen(path, "w");
    if (g) f = g;
  }
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  double cpu_ns = (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1e9
                + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) * 1e3;
  fprintf(f, "TSC_HZ %.0f\n", g_tsc_hz);
  fprintf(f, "CPU_NS %.0f\n", cpu_ns);
  fprintf(f, "CPU_CYCLES_EST %.0f\n", cpu_ns * g_tsc_hz / 1e9);
  for (unsigned long i = 0; i < sizeof(ents)/sizeof(ents[0]); i++) {
    if (ents[i].slot[0])
      fprintf(f, "%s %s %lu %lu\n", ents[i].kind, ents[i].name,
              ents[i].slot[0], ents[i].slot[1]);
  }
  if (f != stderr) fclose(f);
}
""")

with open(OUT_S, "w") as f:
    f.write("\n".join(asm + data) + '\n.section .note.GNU-stack,"",@progbits\n')
with open(OUT_C, "w") as f:
    f.write("\n".join(c) + "\n")

print(f"sym wrapped: {len(sym_names)}")
print(f"z3 wrapped: {len(z3_wrapped)}, skipped(>6 args or unknown): {len(z3_skipped)}")
print("skipped z3:", " ".join(z3_skipped[:20]))
