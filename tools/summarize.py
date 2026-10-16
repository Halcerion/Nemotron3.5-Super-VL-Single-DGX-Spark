#!/usr/bin/env python3
"""summarize.py — Stage C decision table for the Nemotron kit bench.

Reads one or more *_raw*.json files produced by tools/bench.py and prints:
  - per file: per-lane medians (decode tok/s, wall, tokens, spec acceptance)
  - if EXACTLY two files: a K7/K0 speedup table (medianA/medianB per lane)
  - with --mimo <file>: a cross-kit column vs the MiMo kit bench output
    (same schema; flight 7 raw lives at
    ../halcerion-mimo-spark-kit/results/bench-raw-flight7-speed.json)

Usage:
  python3 tools/summarize.py results/bench-raw-nemo-k7-thinkoff.json       results/bench-raw-nemo-k0-thinkoff.json \
      --mimo ../halcerion-mimo-spark-kit/results/bench-raw-flight7-speed.json

Numbers decide the Stage D gate — this tool only formats them. Protocol
rules attached to the numbers: thinking-OFF lanes for speed comparisons;
re-run with --thinking separately for behavioral lanes (#13/#14, MiMo).
"""
import argparse, json, sys

def load(path):
    try:
        with open(path) as f:
            d = json.load(f)
    except FileNotFoundError:
        sys.exit(f"summarize: no such file: {path}")
    except Exception as e:
        sys.exit(f"summarize: {path} unreadable: {e}")
    lanes = {k: v for k, v in d.items() if not k.startswith("_")}
    if not lanes:
        sys.exit(f"summarize: {path} has no lane data (schema from kit bench.py)")
    meta = d.get("_meta", {})
    return lanes, meta

def medians(lanes):
    out = {}
    for lane, block in lanes.items():
        out[lane] = {
            "tok_s": block.get("median_decode_tok_s"),
            "wall_s": block.get("median_wall_s"),
            "tokens": (block.get("runs") or [{}])[0].get("completion_tokens"),
            "accept": block.get("median_spec_accept"),
        }
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+", help="bench.py raw output JSONs (exactly 2 = speedup table)")
    ap.add_argument("--mimo", default="", help="MiMo kit bench raw JSON for the cross-kit column")
    args = ap.parse_args()
    if len(args.files) > 2:
        sys.exit("summarize: pass exactly 1 or 2 files (2 = speedup table)")

    datasets = []
    for p in args.files:
        lanes, meta = load(p)
        m = medians(lanes)
        datasets.append((p, m, meta))
        print(f"== {p}  (thinking={meta.get('thinking')}, max_tokens={meta.get('max_tokens')}) ==")
        for lane in sorted(m):
            r = m[lane]
            acc = r["accept"]
            print(f"  {lane:<12} {r['tok_s']:>8} tok/s   wall {r['wall_s']:>7}s"
                  f"   tokens {r['tokens']}" + (f"   spec accept {acc}" if acc is not None else ""))

    if len(datasets) == 2:
        (pa, ma, ta), (pb, mb, tb) = datasets
        print(f"\n== speedup {pa} / {pb} ==")
        rows = []
        for lane in sorted(set(ma) & set(mb)):
            a, b = ma[lane]["tok_s"], mb[lane]["tok_s"]
            if a and b:
                rows.append((lane, a / b))
                print(f"  {lane:<12} {b:>8.1f} -> {a:>8.1f} tok/s   x{a/b:.2f}")
    # (speedup verdicts belong to Stage D logic - runbook Stage D: promote
    # needs K7 coding >= 46.55 tok/s; this tool only formats the inputs.)

    if args.mimo:
        ml, mm = load(args.mimo)
        mmed = medians(ml)
        a = datasets[0][1]
        print(f"\n== cross-kit: {datasets[0][0]} vs MiMo kit {args.mimo} ==")
        print(f"  {'lane':<12} {'nemo':>9} {'MiMo':>9} {'delta':>8}")
        for lane in sorted(set(a) & set(mmed)):
            n, mmo = a[lane]["tok_s"], mmed[lane].get("tok_s")
            if n and mmo:
                print(f"  {lane:<12} {n:>9.1f} {mmo:>9.1f} {100*(n-mmo)/mmo:>+7.1f}%")
        # MiMo kit reference medians (flight 7, thinking off): coding 46.55,
        # reasoning 48.7, prose 36.1, code_edit 34.6 — printed even without a file
        print("\n  (Stage D gate reference: MiMo flight-7 thinking-off medians "
              "coding 46.55 / reasoning 48.7 / prose 36.1 / code_edit 34.6 tok/s)")

if __name__ == "__main__":
    main()
