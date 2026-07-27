#!/usr/bin/env python3
"""Categorize symprof shim output and print a cost breakdown."""
import sys
from collections import defaultdict

CATS = [
    ("notify_bb/call/ret", lambda n: n in
     ("_sym_notify_basic_block", "_sym_notify_call", "_sym_notify_ret")),
    ("shadow_mem_rw", lambda n: n in
     ("_sym_read_memory", "_sym_write_memory", "_sym_memcpy", "_sym_memmove",
      "_sym_memset", "_sym_register_expression_region")),
    ("param_ret_slots", lambda n: n in
     ("_sym_get_parameter_expression", "_sym_set_parameter_expression",
      "_sym_get_return_expression", "_sym_set_return_expression")),
    ("path_constraint+gc", lambda n: n in
     ("_sym_push_path_constraint", "_sym_collect_garbage", "_sym_feasible",
      "_sym_expr_to_string")),
    ("input_symbolization", lambda n: n in
     ("_sym_make_symbolic", "_sym_get_input_byte", "_sym_initialize",
      "_sym_build_zero_bytes")),
    ("expr_build", lambda n: n.startswith("_sym_build_") or n.endswith("_helper")
     or n in ("_sym_concat_helper", "_sym_extract_helper")),
]


def cat_of(name):
    for cat, pred in CATS:
        if pred(name):
            return cat
    return "other"


def main(paths):
    for path in paths:
        tsc = 1.0
        cpu_ns = 0.0
        rows = []
        with open(path) as f:
            for line in f:
                p = line.split()
                if p[0] == "TSC_HZ":
                    tsc = float(p[1])
                elif p[0] == "CPU_NS":
                    cpu_ns = float(p[1])
                elif p[0] in ("sym", "z3"):
                    rows.append((p[0], p[1], int(p[2]), int(p[3])))
        total_cyc = sum(r[3] for r in rows)
        z3_cyc = sum(r[3] for r in rows if r[0] == "z3")
        z3_cnt = sum(r[2] for r in rows if r[0] == "z3")
        cats = defaultdict(lambda: [0, 0])
        for kind, name, cnt, cyc in rows:
            if kind == "z3":
                continue
            c = cats[cat_of(name)]
            c[0] += cnt
            c[1] += cyc
        # expr_build includes z3 time; split it
        build_cyc = cats["expr_build"][1]
        nonz3_build = max(build_cyc - z3_cyc, 0)
        print(f"\n===== {path}")
        print(f"TSC {tsc/1e9:.2f} GHz | CPU {cpu_ns/1e6:.1f} ms | "
              f"wrapped total {total_cyc/tsc*1e3:.1f} ms "
              f"({100.0*total_cyc/(cpu_ns*tsc/1e9):.1f}% of CPU)")
        print(f"{'category':26s} {'calls':>14s} {'ms':>10s} {'%CPU':>7s} {'ns/call':>9s}")
        cpu_cyc = cpu_ns * tsc / 1e9
        order = sorted(cats.items(), key=lambda kv: -kv[1][1])
        for cat, (cnt, cyc) in order:
            if cat == "expr_build":
                continue
            print(f"{cat:26s} {cnt:14,d} {cyc/tsc*1e3:10.2f} "
                  f"{100.0*cyc/cpu_cyc:6.2f}% {(cyc/max(cnt,1)):9.1f}")
        print(f"{'expr_build (qsym-side)':26s} {cats['expr_build'][0]:14,d} "
              f"{nonz3_build/tsc*1e3:10.2f} {100.0*nonz3_build/cpu_cyc:6.2f}%")
        print(f"{'  └─ inside libz3 (Z3_*)':26s} {z3_cnt:14,d} "
              f"{z3_cyc/tsc*1e3:10.2f} {100.0*z3_cyc/cpu_cyc:6.2f}% "
              f"{(z3_cyc/max(z3_cnt,1)):9.1f}")
        # top individual functions
        print("top functions by cycles:")
        for kind, name, cnt, cyc in sorted(rows, key=lambda r: -r[3])[:12]:
            print(f"  {kind:3s} {name:44s} {cnt:12,d} {cyc/tsc*1e3:9.2f} ms "
                  f"{(cyc/max(cnt,1)):8.1f} ns/call")
        # top z3 functions
        print("top Z3 functions:")
        for kind, name, cnt, cyc in sorted((r for r in rows if r[0] == "z3"),
                                           key=lambda r: -r[3])[:8]:
            print(f"      {name:44s} {cnt:12,d} {cyc/tsc*1e3:9.2f} ms")


if __name__ == "__main__":
    main(sys.argv[1:])
