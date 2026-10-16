#!/usr/bin/env python3
"""toolcall_probe.py — agent-realism tool-call probe (upgrade of the schema-less lane).

The MiMo-inherited toolcall/repetition bench lanes send no tools array, so a
parser-attached tool_calls response is structurally impossible on vLLM
(10/16 flight finding: 0/3 tool_calls with clean `stop` finishes = probe
limit, not model verdict). This probe sends a REAL tools schema the way an
agent harness would: tools=[...] + tool_choice auto, and scores:

  per run: >=1 tool_calls emitted, names valid, arguments parse as JSON,
           no identical call repeated within a run,
  across runs: 3/3 "clean" verdict (the gate's leg).

Usage:
  python3 tools/toolcall_probe.py --base-url "http://127.0.0.1:${PORT}" --api-key "$API_KEY"
      [--runs 3] [--max-tokens 512] [--no-thinking] [--out results.json]
Default: thinking ON (behavioral lane's native shape; the 512-cap run with
max_tokens=512 and finish=length is EXPECTED if the budget starves the call —
use a bigger --max-tokens when thinking is on).
Exit 0 = clean verdict, 2 = any leg failed (evidence printed).
"""
import argparse, json, statistics, time, urllib.request, sys, uuid

TOOLS = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"},
                           "unit": {"type": "string", "enum": ["c", "f"]}},
            "required": ["city", "unit"],
        },
    },
}]
PROMPTS = {
    "toolcall":   "Call the tool get_weather with city='Tulsa' and unit='celsius', then stop.",
    "repetition": "Check the weather for the 5 largest US cities, one per tool call, then stop. Do not repeat a call.",
}

def call(base_url, model, api_key, prompt, max_tokens, thinking, timeout=600):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "tools": TOOLS,
        "tool_choice": "auto",
        "max_tokens": max_tokens,
        "temperature": 0,
        **({} if thinking else {"chat_template_kwargs": {"enable_thinking": False}}),
    }).encode()
    req = urllib.request.Request(base_url.rstrip("/") + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json",
                                          **({"Authorization": f"Bearer {api_key}"} if api_key else {})})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read())
    wall = time.time() - t0
    msg = data["choices"][0].get("message") or {}
    usage = data.get("usage", {})
    return {
        "wall_s": round(wall, 2), "finish_reason": data["choices"][0].get("finish_reason"),
        "content_chars": len(msg.get("content") or ""),
        "reasoning_chars": len(msg.get("reasoning_content") or ""),
        "tool_calls": [{"name": tc.get("function", {}).get("name"),
                        "args": tc.get("function", {}).get("arguments")}
                       for tc in (msg.get("tool_calls") or [])],
        "completion_tokens": usage.get("completion_tokens"),
    }

def score(run):
    ok_calls = []
    seen = set()
    clean_struct = []
    for tc in run["tool_calls"]:
        name = tc["name"]; args = tc["args"]
        try:
            json.loads(args) if isinstance(args, str) else args
            parsed = json.loads(args) if isinstance(args, str) else (args or {})
        except Exception:
            parsed = None
        good = isinstance(name, str) and name and parsed is not None
        clean_struct.append(good)
        if good:
            sig = json.dumps([name, parsed], sort_keys=True)
            if sig in seen:
                return False, "repeated call within run: " + sig
            seen.add(sig)
    return (len(run["tool_calls"]) >= 1 and all(clean_struct)), None

def discover(base_url, api_key=""):
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    req = urllib.request.Request(base_url.rstrip("/") + "/v1/models", headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())["data"][0]["id"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", default=None)
    ap.add_argument("--api-key", default="")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--no-thinking", action="store_true")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    if args.model is None:
        args.model = discover(args.base_url, args.api_key)
        print(f"discovered model id: {args.model}")

    results, clean, fails = {}, 0, 0
    for lane, prompt in PROMPTS.items():
        runs = []
        for i in range(args.runs):
            try:
                run = call(args.base_url, args.model, args.api_key, prompt, args.max_tokens,
                           thinking=not args.no_thinking)
                verdict, why = score(run)
                run["clean"] = verdict
                if why: run["why"] = why
                runs.append(run)
                if not verdict: fails += 1
            except Exception as e:
                fails += 1
                runs.append({"error": str(e), "clean": False})
                print(f"[{lane}] run {i+1} FAILED: {e}", file=sys.stderr)
        clean_n = sum(1 for r in runs if r.get("clean"))
        results[lane] = {"runs": runs, "clean_runs": clean_n,
                         "median_wall_s": statistics.median([r.get("wall_s", 0) for r in runs])}
        print(f"[{lane}] clean {clean_n}/{args.runs}   median wall {results[lane]['median_wall_s']}s")
        for r in runs:
            if not r.get("clean"):
                head = json.dumps({k: r.get(k) for k in ("finish_reason", "content_chars", "reasoning_chars", "tool_calls", "why")})[:280]
                print(f"    DIRTY: {head}")
    verdict = "CLEAN" if fails == 0 else f"{args.runs*2-fails}/{args.runs*2} clean"
    print(f"VERDICT: {verdict} (want {args.runs}/{args.runs} per lane for the gate)")
    out = json.dumps({"_meta": {"max_tokens": args.max_tokens, "thinking_on": not args.no_thinking,
                                "runs": args.runs, "kit": "halcerion-nemotron35-spark-kit"},
                      **results}, indent=2)
    if args.out: open(args.out, "w").write(out)
    sys.exit(0 if fails == 0 else 2)

if __name__ == "__main__":
    main()
