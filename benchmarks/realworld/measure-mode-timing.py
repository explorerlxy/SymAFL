#!/usr/bin/env python3
"""Measure concrete vs QSYM symbolic-stdin execution time for one binary."""

import argparse
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import time


def run_once(binary, data, symbolic, timeout_s):
    env = os.environ.copy()
    if symbolic:
        env.pop("SYMCC_NO_SYMBOLIC_INPUT", None)
    else:
        env["SYMCC_NO_SYMBOLIC_INPUT"] = "1"

    before_wall = time.perf_counter()
    before_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    before_cpu_s = before_cpu.ru_utime + before_cpu.ru_stime
    try:
        proc = subprocess.run(
            [binary],
            input=data,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=timeout_s,
            check=False,
        )
        status = "ok"
        returncode = proc.returncode
    except subprocess.TimeoutExpired:
        status = "timeout"
        returncode = None
    wall_s = time.perf_counter() - before_wall
    after_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu_s = (after_cpu.ru_utime + after_cpu.ru_stime) - before_cpu_s
    return {
        "status": status,
        "returncode": returncode,
        "wall_ms": wall_s * 1000.0,
        "cpu_ms": cpu_s * 1000.0,
    }


def summarize(samples):
    walls = [s["wall_ms"] for s in samples if s["status"] == "ok"]
    cpus = [s["cpu_ms"] for s in samples if s["status"] == "ok"]
    timeouts = sum(1 for s in samples if s["status"] == "timeout")
    returncodes = sorted({s["returncode"] for s in samples if s["returncode"] is not None})
    if not walls:
        return {"timeouts": timeouts, "returncodes": returncodes}
    return {
        "n_ok": len(walls),
        "timeouts": timeouts,
        "returncodes": returncodes,
        "wall_mean_ms": statistics.fmean(walls),
        "wall_median_ms": statistics.median(walls),
        "wall_min_ms": min(walls),
        "wall_max_ms": max(walls),
        "cpu_mean_ms": statistics.fmean(cpus),
        "cpu_median_ms": statistics.median(cpus),
    }


def ratio(concolic, concrete, key):
    if key not in concolic or key not in concrete or concrete[key] == 0:
        return None
    return concolic[key] / concrete[key]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--input", action="append", required=True)
    parser.add_argument("--concrete-reps", type=int, default=30)
    parser.add_argument("--concolic-reps", type=int, default=10)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--output", required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()

    binary = str(Path(args.binary).resolve())
    results = {
        "target": args.target,
        "binary": binary,
        "timeout_s": args.timeout,
        "concrete_reps": args.concrete_reps,
        "concolic_reps": args.concolic_reps,
        "inputs": [],
    }

    for input_name in args.input:
        path = Path(input_name).resolve()
        data = path.read_bytes()
        # Warm both runtime configurations outside the measured samples.
        run_once(binary, data, symbolic=False, timeout_s=args.timeout)
        run_once(binary, data, symbolic=True, timeout_s=args.timeout)

        concrete = [run_once(binary, data, False, args.timeout)
                    for _ in range(args.concrete_reps)]
        concolic = [run_once(binary, data, True, args.timeout)
                    for _ in range(args.concolic_reps)]
        concrete_summary = summarize(concrete)
        concolic_summary = summarize(concolic)
        entry = {
            "input": str(path),
            "size_bytes": len(data),
            "concrete": concrete_summary,
            "concolic": concolic_summary,
            "ratio_wall_mean": ratio(concolic_summary, concrete_summary, "wall_mean_ms"),
            "ratio_wall_median": ratio(concolic_summary, concrete_summary, "wall_median_ms"),
            "ratio_cpu_mean": ratio(concolic_summary, concrete_summary, "cpu_mean_ms"),
        }
        results["inputs"].append(entry)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    print(json.dumps(results, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
