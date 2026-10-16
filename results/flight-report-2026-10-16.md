# Flight report - Nemotron 3.5 Super VL NVFP4 on one DGX Spark (kit #4)

Flight 1, 10/15-10/16/2026. Operator-driven (every box command human-run);
kit authoring and measurement off-box. Raw protocol: greedy, 512 generated
tokens (probe lane 1024), median of 3 runs, batch 1, thinking OFF for speed
lanes, thinking ON for the behavioral probe (with the 1024 budget sized for
the hidden-reasoning channel). Lane prompts are byte-identical to the MiMo
kit bench (halcerion-mimo-spark-kit) for cross-kit comparability:
https://github.com/Halcerion/MiMo-V2.6-Flash-RL-Single-DGX-Spark

Serving shape: stock vllm/vllm-openai:nightly-3f1bcfd82bb2e93fcd364fc7a5491718453a77e2
(the card's own pin; its named v0.32.0 tag is 404-dead on Docker Hub),
LiLiCorr dflash x7, max-num-seqs 1, gpu-memory-utilization 0.75,
max-model-len 114688 (NVIDIA's own Spark serving limit), mamba flashinfer
backend, fp16 SSM cache, port 8895.

## Speed (K7 = LiLiCorr dflash x7 vs K0 = draft OFF, same kit, same protocol)

| Lane | decode tok/s (K7) | wall s (median) | K0 tok/s | speedup |
| --- | --- | --- | --- | --- |
| coding | 56.43 | 9.07 | 18.71 | x3.02 |
| reasoning | 56.42 | 5.89 | 18.72 | x3.01 |
| prose | 26.89 | 14.91 | 18.58 | x1.45 |
| code edit | 37.95 | 8.14 | 18.59 | x2.04 |
| swe (failing-test diagnosis) | 48.0 | 10.67 |

Draft-off decodes FLAT at ~18.6-18.7 tok/s on every lane (the pre-LiLiCorr
A12B signature); the purpose-built drafter multiplies code/reasoning ~x3.0,
edits ~x2.0, prose ~x1.45. The engine reports no per-request acceptance
numbers, so the K7/K0 ratios are the acceptance evidence.

## Behavioral (tools schema attached, tool_choice auto, thinking ON)

| Probe | Verdict | decode tok/s (median, incl. hidden reasoning) |
| --- | --- | --- |
| tool-call JSON | 3/3 clean calls | 43.2 |
| repetition (5 cities requested, single turn) | no repeated calls; clean JSON args | 45.0 |

## Cross-kit reference (MiMo kit flight 7, thinking off, off-box witness)

| Lane | this kit (K7) | MiMo kit | delta |
| --- | --- | --- | --- |
| coding | 56.4 | 46.55 | +21.2% |
| reasoning | 56.4 | 48.7 | +15.9% |
| code edit | 38.0 | 34.6 | +9.7% |
| prose | 26.9 | 36.1 | -25.5% |

(Release-day rerun medians differ by +2-4% run-to-run: coding 58.7 /
reasoning 60.5 / code-edit 38.4 / prose 26.0 / swe 44.6 - consistent.)

## Pre-registered unknowns - all resolved in flight 1

1. v0.32.0 tag 404-dead on Docker Hub -> nightly pin (multi-arch, arm64 ok).
2. Arg acceptance: all flags accepted (JSON --speculative-config + mamba trio).
3. flashinfer mamba backend works on GB10.
4. LiLiCorr acceptance transfers at ~60-65% of the vendor-implied ratio.
5. Thinking is ON by default; reasoning_content never surfaces on this
   nightly - hidden reasoning silently consumes max_tokens (size budgets
   accordingly or disable thinking).

## Mid-flight kit fixes (shipped in this kit)

- --port passed explicitly (vLLM binds 8000 in-container by default; docker
  -p only forwards - publish/listen 1:1).
- Image pin moved to the card's nightly; pull failures print the real docker
  error.
- Preflight OOM gates carry inline remediation + idempotent
  scripts/apply-oom-gates.sh (mkdir + state print + verify-after-write).
- Health wait shows the container's last log line every 60s.
- Banner states real reachability (loopback bind never advertises the box IP).
- Empty API_KEY + non-loopback HOST = a declared open bind (loud warn +
  banner auth NONE); silent exposure stays structurally impossible.
