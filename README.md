# Nvidia Nemotron 3.5 Super on a single DGX Spark - Halcerion Deployment Kit

One command serves **NVIDIA Nemotron 3.5 Super VL 120B-A12B (NVFP4)** on a
single DGX Spark (GB10), with an OpenAI-compatible API. 

## Quick start

```
git clone https://github.com/Halcerion/Nemotron3.5-Super-VL-Single-DGX-Spark.git
cd Nemotron3.5-Super-VL-Single-DGX-Spark
cp .env.example .env  # set API_KEY and HOST=0.0.0.0 to serve on network. PORT defaults to 8895
./start.sh
```

`start.sh` runs six gated steps: 
- preflight (docker, OOM daemon, user.slice MemoryMax cap, MemAvailable water line, auth policy). 
- image pull + GPU probe
- checkpoint download + completeness verification ( Takes a while on first run )
- launch ( Expect initial launch to take up to 40 minutes for model download, after that around 10 )
- health + discovery smoke 
- LIVE banner means you're ready to roll. 

The script refuses to launch rather than discovering problems mid-load. If you hit any preflight failures the script will print their remediation inline. If you hit the MemoryMax or OOM check specifically, run `sudo bash scripts/apply-oom-gates.sh` to install/enable systemd-oomd and verifies the 120G user.slice cap.

## Model Details:

* Mamba-2/attention/MoE hybrid (512 routed experts per MoE layer)
* 120B total / 12B active parameters
* C-RADIO vision encoder with image + video input
* native multi-token prediction plus a purpose-built LiLiCorr parallel drafter
(dflash, 7-slot). 
* Serves text, vision, and video; tool calling and configurable reasoning mode (enable_thinking in the chat template).

| Spec | Value |
| --- | --- |
| Weights on disk | ~70 GiB 
| Checkpoint tensor params | 65.77B (post-quant layout) 
| Drafter | ~1.0B params (~3 GiB) 
| Context on Spark | 114,688 (NVIDIA's serving setting) 
| License | OpenMDW-1.1 (commercial OK) 


## Serving shape (stock vLLM, no custom image)

* IMAGE (full pin in `.env.example`): vllm/vllm-openai:nightly-3f1bcfd82bb2e93fcd364fc7a5491718453a77e2
  runs on port 8895 | max-num-seqs 1 | gpu-memory-utilization 0.75 | max-model-len 114688
* LiLiCorr dflash x7 (SPEC_TOKENS=0 disables for a draft-off baseline)
* Memory math: 0.75 x ~121.6 GiB usable = ~91 GiB pool leaving ~30 GiB for the host

## Measured Performance

Benchmarks run against the live container on a single DGX Spark, thinking OFF
(Greedy, 512 generated tokens, median of 3, batch 1 — byte-identical
prompts to the [MiMo kit](https://github.com/Halcerion/MiMo-V2.6-Flash-RL-Single-DGX-Spark)
bench for direct comparison):

| Test | DGX Spark |
|---|----|
| coding, LiLiCorr dflash | 58.7 tok/s |
| reasoning, dflash | 60.5 tok/s |
| swe (failing-test diagnosis), dflash | 44.6 tok/s |
| code edit, dflash | 38.4 tok/s |
| prose, dflash | 26.0 tok/s |
| tool-call JSON (real tools schema, thinking on, 1024 budget) | 3/3 clean calls @ 43.2 tok/s |
| repetition probe (5 cities requested, single turn) | no repeated calls; clean JSON args @ 45.0 tok/s |

Draft-off baseline: an ~18.6-18.7 tok/s flat ceiling on every lane — the
LiLiCorr dflash x7 drafter is what makes this model fast, multiplying the
code/reasoning lanes ~x3.0, edits ~x2.0, and prose ~x1.45 (the engine does
not report per-request acceptance; the K7/K0 ratios are the evidence).

Full data in `results/flight-report-2026-10-16.md` and `results/toolcall-probe-k7.json`.

## Bench

    source .env
    python3 tools/bench.py --base-url "http://127.0.0.1:${PORT}" --api-key "$API_KEY" \
        --out results/bench-raw-nemo-thinkoff.json

Protocol per lane: greedy, 512 tokens, median of 3, batch 1, thinking OFF.

Draft-off baseline (the interesting science: raw 12B-active decode ceiling):

    # .env: SPEC_TOKENS=0, then ./start.sh restart, bench, restore, restart again

## Security

* Defaults to localhost only with HOST=127.0.0.1 (keyless, loopback-safe). 
* To serve on a local network set HOST=0.0.0.0 and we recommend setting the API_KEY as well
* Hosting on the network without a key will display a warning in the launch banner as a reminder

## Credits

- NVIDIA: model, quant, LiLiCorr drafter, and the DGX Spark Quick Start packages.
- vLLM project + vllm/vllm-openai container.
- Kit pattern: Halcerion MiMo kit (halcerion-mimo-spark-kit); MiaAI-Lab
  single-Spark kit heritage.
- Weights: OpenMDW-1.1. Kit code: Apache-2.0.
