# Flight runbook — Nemotron 3.5 Super VL NVFP4 on DGX Spark (kit #4)

Owner: the Spark operator runs all box-side commands; kit authoring/results-prep happens off-box.
Draft state 10/15/2026: scaffold complete and self-tested, ZERO box time spent.
Standing rules in force: video/ComfyUI jobs own the box exclusively while
they run (stop before launching this kit); the MiMo kit (8888) stays the
LIVE main lane until this kit WINS its bench.

## 0. Verified model facts (checked 10/15/2026, pre-flight - do not re-transcribe loosely)

- Target repo: nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4
  - 65,769,840,138 checkpoint params; usedStorage 75,049,013,059 B = ~69.9 GiB
  - arch: NemotronH_Omni_Reasoning_V3, model_type nemotron_h_omni, CUSTOM CODE
    (auto_map -> modeling_nemotron_h_omni.py in-repo) => --trust-remote-code REQUIRED
    (the files ride the mounted snapshot; no runtime fetch)
  - ungated + public: no HF token needed
  - tensor mix: U8 58.68B params (NVFP4) + F8 5.21B + BF16 1.88B + F32 iota
- Drafter repo: ...NVFP4-LiLiCorr — 1.13B dense GQA drafter + 37M corr head +
  0.54B NVFP4 copy of the target LM head; ~1.0B params checkpoint; ~2-3 GiB
- DFlash slots 7; vendor acceptance (SPEED-Bench, k=7): 4.74 accepted/step avg
  @ T=0 (coding 5.65 / humanities 3.78), 4.36 @ T=1
- NVIDIA's OWN Spark serve config (card Quick Start): max-num-seqs 1, util
  0.75, ctx 114,688, --video-pruning-rate 0.5, fps 2 / 256 frames, tool parser
  qwen3_coder, reasoning parser nemotron_v3, mamba flashinfer + fp16 SSM cache
  + stochastic rounding + philox 5 + shared-prefix checkpoint
- Images named by the card: vllm/vllm-openai:v0.32.0 and a pinned nightly
- Spark decode math (pre-registered expectation): 12B active @ ~4.25 bit
  ≈ 6.4 GB/token -> ~35-40 steps/s bandwidth ceiling -> x4.3-4.7 accepted =>
  ~100-180 tok/s IF acceptance transfers to GB10; ~35-40 raw with draft off.
  The old A12B verdict (~16-20 tok/s) assumed no drafter — this card's
  drafter is the whole bet.

## Preconditions (Standing)

1. Any ComfyUI/video-generation job on the box is STOPPED (exclusivity rule:
   a ~45 GB diffusion pack and this kit cannot co-reside); `free -h` shows
   >= 118 GiB available idle.
2. OOM stack verified (start.sh hard-gates it): systemd-oomd active,
   user.slice MemoryMax=120G drop-in live. If a gate stops you:
   `sudo bash scripts/apply-oom-gates.sh` brings the whole stack up and
   verifies effective values (appendix A has manual steps). History
   correction 10/15 (first flight hit this on the box): what 9/20 verified live
   was the oomd UNIT's absence; the 120G drop-in was prescribed then but its
   persistence was never confirmed - and the MiMo kit's start.sh never
   checked MemoryMax at all (runbook checklist only). "user.slice the unit"
   always exists (ships with systemd); "/etc/systemd/system/user.slice.d/"
   is OUR dir and was ABSENT - i.e. the cap was never persistently applied
   (or was later removed; `ls -la` + step-0 state print in
   apply-oom-gates.sh make the record explicit either way).
3. Swap sequence (this kit vs MiMo kit are mutually exclusive):
     cd <mimo-kit-dir> && ./stop.sh     # free the ~113 GiB the other kit holds
     cd <kits-dir-on-the-spark>/halcerion-nemotron35-spark-kit && ./start.sh
   Rollback is the same two commands in reverse (~10 min loads both ways).
4. flock /tmp/gpu.lock gates launches (fail-fast, non-blocking).

## Stage B — box setup (no launch)

- [ ] Sync kit: rsync -a halcerion-nemotron35-spark-kit/ <user>@<spark-host>:<kit-dir>/
- [ ] cp .env.example .env; set HOST=0.0.0.0 + API_KEY (openssl rand -hex 24)
      [loopback-only dry run may skip]
- [ ] docker pull of the kit's IMAGE default (the card's nightly pin -
      multi-arch incl arm64 confirmed 10/16; arm64 layer ~10.7 GB, first pull is slow)
- [ ] Downloads happen inside ./start.sh (~73 GiB, resumable); disk gate needs
      80G free — if tight, `docker system df` + old Mia pack (~99 GiB) are the
      reclaim candidates BEFORE touching MiMo/kit dirs.

## Stage A — first flight

- [ ] ./start.sh with FOREGROUND=1 in a second tmux pane watching `free -h`
- [ ] EXPECT: pull (skipped) -> GPU probe -> disk gate -> downloads (long,
      resumable) -> verify_model gates (~2s) -> container start -> health.
      First health can take a while: mamba/flashinfer kernel compile. Gate:
      HEALTH_TIMEOUT=2700. Compile cache persists in MODELS_DIR/vllm-cache
      (mounted /root/.cache/vllm) — restarts get cheaper.
- [ ] Banner + smoke (thinking OFF, HALCERION-KIT-OK) must both pass.
- Record: cold load wall time, healthy-with-compile vs warm restart delta.

## Stage C — bench matrix (all lanes thinking-off unless noted)

    source .env
    python3 tools/bench.py --base-url "http://127.0.0.1:${PORT}" --api-key "$API_KEY" \
        --out results/bench-raw-nemo-k7-thinkoff.json
    python3 tools/bench.py --base-url "http://127.0.0.1:${PORT}" --api-key "$API_KEY" \
        --thinking --lanes toolcall,repetition \
        --out results/bench-raw-nemo-k7-thinkon-behavior.json

Then the draft-off baseline:
    # .env SPEC_TOKENS=0 -> ./start.sh restart -> bench (same filename -
    k0) -> restore

Summary table (input to Stage D — run after the K7 and K0 benches):

    python3 tools/summarize.py results/bench-raw-nemo-k7-thinkoff.json \
        results/bench-raw-nemo-k0-thinkoff.json \
        --mimo ../halcerion-mimo-spark-kit/results/bench-raw-flight7-speed.json

Prints per-lane medians (with spec acceptance when reported), the K7/K0
speedup ratio per lane, and the cross-kit delta column vs the MiMo kit raw.
Tested against the real flight-7 file — schemas match across kits.
Tool-call gate leg (agent-realism probe WITH a real tools schema - the
schema-less bench lane cannot legally emit tool_calls on vLLM; 10/16 flight:
0/3 with clean stop finishes = probe limit, not model verdict):

    python3 tools/toolcall_probe.py --base-url "http://127.0.0.1:${PORT}" --api-key "$API_KEY" \
        --max-tokens 1024 --out results/toolcall-probe-k7.json

512 + thinking-on = budget-starved (see pitfalls 17).

Comparison targets (MiMo kit flight 7, thinking-off medians): coding 46.55 /
reasoning 48.7 / prose 36.1 / code_edit 34.6 tok/s; toolcall 48 tok/s 3/3
clean. Acceptance: usage.spec_accept_length if the engine reports, else
speedup ratio K7/K0 per lane. Protocol rules from lessons: record thinking
off AND on columns; wall numbers are end-to-end (off-box), never transcribe a
vendor table from a report gloss.

Optional experiment (document, don't tune): MAX_SEQS=4 restart - pool unchanged,
per-seq KV shrinks; one sentence of observation only.

## Pre-registered unknowns (fill these, then judge)

| # | Unknown | Probe / fallback |
| --- | --- | --- |
| 1 | v0.32.0 image has linux/arm64? | RESOLVED 10/16: the tag is 404-DEAD on Docker Hub ('0.32.0' too). Card's nightly pin is multi-arch (arm64 layer ~10.7 GB, manifest-list sha256:cb9bc6...); kit IMAGE default flipped to it. Fallbacks: muse-spark-open (multi-arch, unverified), NGC vLLM container |
| 2 | api_server accepted our arg list (`vllm serve `-equivalent flags)? | first start; if flag rejected, read `docker run --rm IMAGE vllm serve --help`; adapt kitting only if needed | RESOLVED 10/16: all flags accepted (incl JSON --speculative-config + the mamba trio).
| 3 | flashinfer mamba backend works on GB10 (SM121)? | first start; fallback: nightly image (NVIDIA validated there) | RESOLVED 10/16: works on GB10 (the nightly pin is the working image).
| 4 | LiLiCorr acceptance on GB10 ≈ vendor 4.74? | spec_accept_length field or K7/K0 speedup ratio | RESOLVED 10/16: engine reports no per-request acceptance; K7/K0 speedups are the evidence: x3.02 coding / x3.01 reasoning / x2.04 code_edit / x1.45 prose.
| 5 | Does reasoning mode default ON server-side? | smoke already forces thinking OFF; verify a thinking-on response has reasoning_content | RESOLVED 10/16: thinking IS on by default (133 completion tokens surfaced 3 content chars) AND reasoning_content never surfaces on this nightly - hidden reasoning silently consumes budget; size thinking-on budgets past it (or disable).
| 6 | Pool really fits (~91 GiB, weights ~67 + SSM/KV/drafter)? | watch free -h during load; on OOM at load: util 0.80 step (NOT up) or MAX_MODEL_LEN down |

## Stage D — decision gate (numbers decide, written before flight)

- CONTINUE as quality lane: K7 coding lane >= MiMo kit's 46.55 tok/s AND
  smoke/toolcall clean AND no OOM incident.
- PROMOTE to 8888 main: all of the above AND prose lane >= 36.1 AND a
  thinking-on quality spot check (2 real prompts vs MiMo kit outputs,
  blind-read) shows no regression.
- KILL: K7 decode < 20 tok/s (acceptance collapsed — old A12B story returns),
  or both image tags fail stage A, or OOM at load with util 0.75.
- If killed: kit stays published as an artifact with honest results (the
  negative result IS the artifact), MiMo kit stays main.

## Pitfalls (mapped lessons, live checklist)

1. Dotted --speculative_config.* on the card -> we pass one JSON
   --speculative-config (version-robust); only switch if a flag is rejected.
2. --media-io-kwargs JSON is a single-quoted literal in the args array; never
   env-interpolate inside it.
3. ctx 114,688 is NVIDIA's own Spark limit. Do not "fix" toward 1M without
   pool math (same class as the MiMo kit's util-0.80 do-not-touch rule).
4. GPU probe runs AFTER image exists; driver-wedge rule: nvidia-smi alive +
   torch CUDA dead BOTH paths => reboot before toolkit surgery.
5. Disk gate walks UP to the nearest existing ancestor (fabricated-0G lesson).
6. verify_model.py runs BEFORE the first 10-minute load cycle (flight-5 lesson).
7. No --exclude on hf download unless one-pattern-per-flag (lesson); we ship none.
8. Health poll exits fast on container-not-running (restart-loop lesson).
9. Banner: printf \uXXXX only; IP via `ip -4 route get 1.1.1.1` src.
10. Container cgroup OOM is NOT protected by user.slice MemoryMax (system
    slice) - the pool sizing + NEED_HOST_GIB gate are the real guard.
11. A video/ComfyUI pack and this kit cannot co-reside (~45 GB + 91 GiB
    pool). Stop it first; the MemAvailable gate catches it if forgotten.
12. docker -p decides reachability; the auth guard checks the SAME variable.
13. Headerless drop-ins ([Slice] missing) parse to NOTHING silently - the
    preflight probes the effective MemoryMax, and apply-oom-gates.sh verifies
    after writing (probe-what-you-built).
14. 9/18 paste-split lesson: never paste multi-command `&&` chains with
    redirects into an ssh terminal. Use scripts/apply-oom-gates.sh (a file),
    or edit the drop-in with sudo nano (appendix A shows the exact contents).
15. Card-quoted image tags can be dead on publication: v0.32.0 (both spellings)
    404 on Hub the day after release. One URL check settles a tag question:
    https://hub.docker.com/v2/repositories/vllm/vllm-openai/tags/<tag>
    (images[].architecture lists arm64 when multi-arch). Pull-failure die now
    prints the real docker error - read it before reacting to the generic text.
16. Publish/listen must match: vLLM binds 8000 INSIDE the container unless
    --port is passed; docker -p only forwards. First flight 10/16: published
    8895, uvicorn listened on 8000 -> /health 000 for the whole wait.
    Symptom signature: "docker port" shows the mapping, curl gets 000, logs
    say "Application Startup complete" (on the other port). Kit now passes
    --port "$PORT" (1:1). Fast path without the fix: PORT=8000 in .env.
17. Behavioral lanes need a REAL tools array (bench.py's schema-less lane
    cannot emit tool_calls on vLLM - use toolcall_probe.py), and thinking-on
    + max_tokens 512 is budget-starved: 10/16 flight saw finish=length with
    content 0 AND reasoning 0 (the thinking channel invisible to our payload
    shape - open question, unknown #5). Upgraded probes run with 1024+.
18. Open-bind is a DECLARED state: empty API_KEY + non-loopback HOST warns
    loudly at preflight (LAN + tailscale IPs) and the banner shows auth: NONE
    (gate amended 10/16 from a hard die - the 9/19 class bug was silent
    exposure, never a loud deliberate one).

## Publication plan (artifact #4)

- Repo-only kit (no GHCR image needed — stock image). Same discipline as the
  MiMo kit 10/6 parity pass before publish: every README command actually run.
- Publish flow (credentialed push is the operator's): orphan clean-identity branch for the
  public face if we follow the MiMo pattern; internal history stays internal.
- Results land in results/ (bench-raw-*.json gitignored; medians in README).


## Appendix A - OOM gate remediation (what preflight refuses on)

Why these gates exist: on the GB10, GPU memory IS system memory. A runaway
CUDA allocation (or a second model served by accident) does not OOM-kill
tidily - it drags the whole box down into a hard freeze (the pre-kit
community incident cost two days). The launch policy is therefore: an OOM
daemon running, and user.slice capped at 120G (of 121.6 GiB usable), so the
kernel has a clean cgroup boundary to kill inside.

Recommended remediation (idempotent, verifies after applying):

    sudo bash scripts/apply-oom-gates.sh

It installs systemd-oomd if the unit file is absent, enables it, writes the
drop-in, daemon-reloads, then verifies EFFECTIVE state (is-active +
MemoryMax value). Exit 0 only when both gates are real.

Manual path (paste-split lesson: single commands, no && chains; or nano):

    # 1) daemon
    sudo apt install -y systemd-oomd
    sudo systemctl enable --now systemd-oomd

    # 2) cap - the dir is OURS, not systemd's: create it first.
    sudo mkdir -p /etc/systemd/system/user.slice.d

    # 3) drop-in - single-paste heredoc, or sudo nano with the same contents.
    #    The [Slice] header is REQUIRED (headerless drop-ins parse to nothing).
    sudo tee /etc/systemd/system/user.slice.d/oom-protection.conf >/dev/null <<'EOF'
    [Slice]
    MemoryMax=120G
    ManagedOOMMemoryPressure=kill
    ManagedOOMMemoryPressureLimit=80%
    EOF
    sudo systemctl daemon-reload

Verify (expect 'active' and 128849018880):

    systemctl is-active systemd-oomd
    systemctl show user.slice -p MemoryMax --value

If MemoryMax still shows 'infinity': the file is not under
/etc/systemd/system/user.slice.d/ (most common: the dir itself was never
mkdir'd - systemd ships the unit, never our drop-in dir), the [Slice]
header is missing/misspelled, or typos in the values - `systemctl show user.slice` prints parse warnings in
the journal (`journalctl -u systemd` or check `SystemdUnitFiles` probing). On
non-DGX-OS boxes (no apt): install systemd-oomd or earlyoom per your distro
and apply the drop-in contents manually above.

History note (corrected 10/15): 9/20 verified live only the oomd unit's
ABSENCE ("Failed to enable: Unit file systemd-oomd.service does not exist" -
DGX OS 7.x ships without it); the 120G drop-in was prescribed the same day
but its on-disk persistence was never confirmed, and the MiMo kit's start.sh
had no MemoryMax gate (the check lived in the runbook checklist). The 10/15
probe found /etc/systemd/system/user.slice.d ABSENT - consistent with either
never-persisted or later-removed. apply-oom-gates.sh step 0 prints the full
state (versions, unit presence, dir/file, effective MemoryMax) so the next
run carries an explicit record instead of an assumption.
