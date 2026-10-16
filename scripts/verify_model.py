#!/usr/bin/env python3
"""verify_model.py — checkpoint completeness gate BEFORE the first costly load.

MiMo flight-5 lesson: a dangling/missing drafter staged via symlinks cost a
full ~9-minute cold-load cycle before discovery. This gate catches incomplete
checkpoints in ~2s instead. Generic for any HF-format model dir:

  - config.json present
  - >=1 *.safetensors, none zero-byte
  - if model.safetensors.index.json exists: every shard it names exists and
    is non-empty (shard-count cross-check)
  - real on-disk bytes (symlinks followed, du -sb semantics) >= --min-gib

Usage: python3 scripts/verify_model.py <dir> --min-gib 65 [--name main]
Exit 0 = pass, 2 = fail (reasons printed).
"""
import argparse, json, os, sys

def human_gib(n):
    return n / (1024 ** 3)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("--min-gib", type=float, default=0.0)
    ap.add_argument("--name", default="checkpoint")
    args = ap.parse_args()
    d = args.model_dir
    errors = []

    if not os.path.isdir(d):
        sys.exit(f"FATAL: {d} is not a directory")

    if not os.path.isfile(os.path.join(d, "config.json")):
        errors.append("config.json missing (download incomplete?)")

    shards = []
    for root, _, files in os.walk(d):
        for fn in files:
            if fn.endswith(".safetensors"):
                p = os.path.join(root, fn)
                try:
                    sz = os.stat(p).st_size  # follows symlinks; dangling raises
                except OSError as e:
                    errors.append(f"unreadable shard (dangling symlink?): {p}: {e}")
                    continue
                shards.append((p, sz))

    if not shards:
        errors.append("no .safetensors files found")
    else:
        zero = [p for p, s in shards if s == 0]
        if zero:
            errors.append(f"zero-byte shard(s): {zero}")

    index_path = os.path.join(d, "model.safetensors.index.json")
    if os.path.isfile(index_path):
        try:
            with open(index_path) as f:
                index = json.load(f)
            named = sorted(set(index.get("weight_map", {}).values()))
            have = {os.path.basename(p) for p, _ in shards}
            missing = [s for s in named if s not in have]
            if missing:
                errors.append(f"index names {len(named)} shards, {len(missing)} missing on disk, e.g. {missing[:3]}")
            else:
                print(f"  index check: {len(named)} named shards all present")
        except Exception as e:
            errors.append(f"index unreadable: {e}")
    else:
        print("  (no shard index — single-file or unusual layout, skipping index check)")

    total = sum(s for _, s in shards)
    total_all = 0
    for root, _, files in os.walk(d):
        for fn in files:
            try:
                total_all += os.stat(os.path.join(root, fn)).st_size
            except OSError as e:
                errors.append(f"unreadable file (dangling symlink?): {os.path.join(root, fn)}: {e}")

    gib = human_gib(total)
    print(f"  {args.name}: {len(shards)} shard(s), weights total {gib:.2f} GiB, dir total {human_gib(total_all):.2f} GiB")
    if gib < args.min_gib:
        errors.append(f"weights total {gib:.2f} GiB < required {args.min_gib} GiB")

    if errors:
        for e in errors:
            print(f"  FAIL: {e}", file=sys.stderr)
        sys.exit(2)
    print(f"  verify_model: {args.name} COMPLETE")

if __name__ == "__main__":
    main()
