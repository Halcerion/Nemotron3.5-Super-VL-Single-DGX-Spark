#!/usr/bin/env bash
# start.sh — Halcerion kit #4: NVIDIA Nemotron 3.5 Super VL 120B-A12B (NVFP4) on one DGX Spark.
# Target:  nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4
# Drafter: nvidia/...-NVFP4-LiLiCorr (dflash, 7-slot parallel drafting)
# Engine:  stock vLLM container (vllm/vllm-openai:v0.32.0) — no custom image build.
# Pattern: Halcerion MiMo kit (halcerion-mimo-spark-kit); MiaAI-Lab single-Spark heritage.
#
# Steps: preflight (oomd gates) -> image + GPU probe -> checkpoints (download+verify)
#        -> launch -> wait healthy -> discovery smoke -> LIVE banner
# Env/.env: see .env.example. Container name: halcerion-nemotron35-spark
#
# Serve flags mirror NVIDIA's DGX Spark Quick Start on the model card (10/15/2026),
# EXCEPT the card's dotted --speculative_config.* sugar is collapsed into the
# version-robust JSON form (--speculative-config). ctx is NVIDIA's own Spark
# serving limit (114,688), not the 1M card headline.
set -euo pipefail
cd "$(dirname "$0")"

# ---------- config (env wins over .env) ----------
RESTART=0
case "${1:-}" in
  "") ;;
  restart) RESTART=1 ;;
  *) printf 'unknown argument: %s (usage: ./start.sh [restart])\n' "$1" >&2; exit 2 ;;
esac
if [ -f .env ]; then
  set -a; source .env; set +a
fi
PORT="${PORT:-8895}"
HOST="${HOST:-127.0.0.1}"
API_KEY="${API_KEY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-halcerion-nemotron35-spark}"
# v0.32.0 is DEAD on Docker Hub (404, checked 10/16; '0.32.0' no-v too) -
# default is the card's own nightly pin: hash-suffixed tag, effectively
# immutable, and the only image NVIDIA validated this model's config against.
IMAGE="${IMAGE:-vllm/vllm-openai:nightly-3f1bcfd82bb2e93fcd364fc7a5491718453a77e2}"
MODEL_REPO="${MODEL_REPO:-nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4}"
DRAFT_REPO="${DRAFT_REPO:-nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4-LiLiCorr}"
MODELS_DIR="${MODELS_DIR:-$HOME/.cache/halcerion/nemotron-3.5-super-vl}"
MAIN_DIR="$MODELS_DIR/main"
DRAFT_DIR="$MODELS_DIR/draft"
VLLM_CACHE_DIR="$MODELS_DIR/vllm-cache"
SERVED_NAME="${SERVED_NAME:-nemotron-3.5-super-vl}"
MAX_SEQS="${MAX_SEQS:-1}"
SPEC_TOKENS="${SPEC_TOKENS:-7}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.75}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-114688}"
MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-8192}"
NEED_HOST_GIB="${NEED_HOST_GIB:-95}"
DISK_NEED_GIB="${DISK_NEED_GIB:-80}"
MIN_MODEL_GIB="${MIN_MODEL_GIB:-65}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-2700}"

# ---------- helpers ----------
step()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m  \u2713 %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
info()  { printf '\033[1;34m  i %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m  \u2717 %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

# ---------- numeric sanity on the knobs we interpolate ----------
case "$SPEC_TOKENS" in ''|*[!0-9]*) die "SPEC_TOKENS must be an integer (0 = draft off): $SPEC_TOKENS" 2 ;; esac
case "$MAX_SEQS" in ''|*[!0-9]*) die "MAX_SEQS must be an integer: $MAX_SEQS" 2 ;; esac

# ---------- 1. preflight ----------
step "1/6 Preflight (unified-memory gates)"
command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (group? nvidia runtime?)"

# OOM daemon gate. DGX OS 7.x ships WITHOUT systemd-oomd; on a unified-memory
# box a runaway CUDA alloc hard-freezes the whole machine, so we refuse to
# launch with no OOM protection at all (MiMo standing rule).
if systemctl is-active --quiet systemd-oomd 2>/dev/null; then
  ok "systemd-oomd active"
elif pgrep -x earlyoom >/dev/null 2>&1; then
  ok "earlyoom active"
else
  die "no OOM daemon running (systemd-oomd or earlyoom).
  Why the gate: unified-memory DGX Spark - a runaway CUDA alloc freezes the WHOLE
  box, so start.sh refuses to launch unprotected instead of discovering OOM by freeze.
  Remedy A (recommended): sudo bash scripts/apply-oom-gates.sh   (idempotent, verifies after)
  Remedy B (manual):      sudo apt install -y systemd-oomd
                          sudo systemctl enable --now systemd-oomd
  Details: docs/flight-runbook.md appendix A" 3
fi

# user.slice MemoryMax drop-in (120G) — verified live on the box since 9/20.
# A drop-in WITHOUT a [Slice] section header parses silently to nothing, so we
# probe the effective value, not the file (audit lesson: probe-what-you-built).
MEMMAX=$(systemctl show user.slice -p MemoryMax --value 2>/dev/null || true)
if [ -z "$MEMMAX" ] || [ "$MEMMAX" = "infinity" ]; then
  die "user.slice MemoryMax is NOT capped (effective value: ${MEMMAX:-<unset>}).
  Why the gate: without a cgroup cap the runaway-process failure mode here is a
  whole-box freeze, not an OOM kill. Policy: user.slice capped at 120G (121.6 GiB usable).
  Remedy A (recommended): sudo bash scripts/apply-oom-gates.sh   (idempotent, verifies after)
  Remedy B (manual):      sudo mkdir -p /etc/systemd/system/user.slice.d
                          (systemd ships the user.slice UNIT but never creates
                          this drop-in dir; absent dir = cap was never applied)
                          then edit /etc/systemd/system/user.slice.d/oom-protection.conf
                          (use nano - do NOT paste && chains into an ssh terminal; paste-split lesson)
                          contents:
                            [Slice]
                            MemoryMax=120G
                            ManagedOOMMemoryPressure=kill
                            ManagedOOMMemoryPressureLimit=80%
                          note: the [Slice] header is REQUIRED; a headerless
                          drop-in parses to nothing, exactly like an absent file
                          then: sudo systemctl daemon-reload
  Verify it took:         systemctl show user.slice -p MemoryMax --value
                          (expect 128849018880 = 120G; 'infinity' = not applied)
  Then re-run ./start.sh. If still uncapped see runbook appendix A." 3
fi
ok "user.slice MemoryMax=$MEMMAX"

FREE_GIB=$(awk '/MemAvailable/ {printf "%.1f", $2/1048576}' /proc/meminfo)
# Enforced gate (unified memory: CUDA OOM freezes the whole machine). This
# catches the exact real failure: another big model (the other kit) or a
# video/ComfyUI pack still holding memory when this kit launches. NEED_HOST_GIB=95 assumes the
# GPU_MEM_UTIL=0.75 pool (~91 GiB on 121.6 GiB usable); lower util => lower gate.
if awk -v f="$FREE_GIB" -v n="$NEED_HOST_GIB" 'BEGIN { exit !(f < n) }'; then
  die "MemAvailable ${FREE_GIB} GiB < required ${NEED_HOST_GIB} GiB — something else is holding memory (the OTHER model still resident? stop it first (runbook Stage A swap sequence)sh). Override: NEED_HOST_GIB=<N> in .env" 3
fi
ok "MemAvailable: ${FREE_GIB} GiB (gate: ${NEED_HOST_GIB} GiB)"

if docker ps --format '{{.Names}}' | grep -v "^${CONTAINER_NAME}$" | grep -q .; then
  warn "other containers running - one-model-at-a-time rule; stop them first if they hold GPU"
  docker ps --format '    {{.Names}} ({{.Image}})'
fi
# Auth contract (amended 10/16, was a hard die): empty API_KEY + non-loopback
# HOST = a DELIBERATE open bind. The 9/19 class bug was SILENT exposure
# (guard checking one variable, runtime using another) - a declared open state
# with a loud warning is the operator's call; what stays forbidden is exposure
# nobody knows about.
AUTH_OPEN=0
if [ -n "$API_KEY" ]; then
  ok "API key: set (Bearer enforced)"
elif [ "$HOST" = "127.0.0.1" ]; then
  ok "API key: unset, loopback bind - keyless is safe here"
else
  AUTH_OPEN=1
  TSIP=$(tailscale ip -4 2>/dev/null | head -1)
  warn "AUTH OPEN: no API_KEY with bind ${HOST} - the whole LAN${TSIP:+ AND tailscale ${TSIP}} can reach this GPU unauthenticated"
  warn "this is the deliberate .env state (API_KEY empty); set API_KEY to close"
fi

# ---------- 2. image ----------
step "2/6 Image ($IMAGE)"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "image present"
else
  # Show the REAL docker error before dying (10/16 lesson: the generic die text
  # sent the operator scrolling for the cause).
  if ! PULL_ERR=$(docker pull "$IMAGE" 2>&1); then
    printf '%s\n' "$PULL_ERR" | tail -4
    die "image pull failed (error above). Known ground truth (Hub API, 10/16): the card's v0.32.0 tag is 404-dead; the kit default nightly pin is multi-arch (arm64 layer ~10.7 GB - first pull is slow, be patient). Other causes: Hub rate limit (wait or docker login)." 4
  fi
  ok "pulled: $IMAGE"
fi
# GPU proof - run AFTER image presence is guaranteed (audit lesson: probing
# before the image existed silently skipped this check on a flight).
# Driver-wedge rule (9/19): NVML-alive + CUDA-init-dead survives nvidia-smi;
# a reboot fixes it before any toolkit surgery.
if ! docker run --rm --gpus all --entrypoint python3 "$IMAGE" -c "import torch; assert torch.cuda.is_available()" >/dev/null 2>&1; then
  die "GPU probe failed with image present - CUDA interface dead; driver-wedge rule: REBOOT before toolkit surgery (9/19 lesson)" 4
fi
ok "GPU probe: CUDA live in container"

# ---------- 3. checkpoints ----------
step "3/6 Checkpoints (~73 GiB total: ~70 target + ~3 drafter, resumable)"
# NOTE: the dir may not exist yet — walk UP to the nearest existing ancestor so
# we measure the real filesystem the pack will land on, not a nonexistent one
# (lesson: df on a nonexistent path renders a fabricated 0G).
DISK_PATH="$MODELS_DIR"
while [ ! -d "$DISK_PATH" ] && [ "$DISK_PATH" != "/" ]; do
  DISK_PATH="$(dirname "$DISK_PATH")"
done
DISK_FREE=$(df -BG "$DISK_PATH" 2>/dev/null | tail -1 | awk '{print $4}' | tr -dc '0-9')
if [ -z "$DISK_FREE" ] || [ "$DISK_FREE" -lt "$DISK_NEED_GIB" ]; then
  die "only ${DISK_FREE:-?}G free on ${DISK_PATH} (real fs: $(df "$DISK_PATH" 2>/dev/null | tail -1 | awk '{print $1}')) - need ~${DISK_NEED_GIB}G for both repos (check Mia's old pack for reclaimable space)" 5
fi
ok "disk gate: ${DISK_FREE}G free on ${DISK_PATH}"

mkdir -p "$MAIN_DIR" "$DRAFT_DIR" "$VLLM_CACHE_DIR"
# NO --exclude patterns anywhere (lesson: hf download applies one pattern per
# --exclude; extra patterns become positional filenames). We exclude nothing.
if [ ! -f "$MAIN_DIR/config.json" ]; then
  if command -v hf >/dev/null; then
    hf download "$MODEL_REPO" --local-dir "$MAIN_DIR"
  else
    docker run --rm -v "$MAIN_DIR:/out"       -e HF_TOKEN="${HF_TOKEN:-}"       "$IMAGE" python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('$MODEL_REPO', local_dir='/out')
"
  fi
fi
[ -f "$MAIN_DIR/config.json" ] || die "main checkpoint incomplete after download"
python3 scripts/verify_model.py "$MAIN_DIR" --min-gib "$MIN_MODEL_GIB" --name main
ok "main checkpoint ready at $MAIN_DIR"

if [ ! -f "$DRAFT_DIR/config.json" ]; then
  if command -v hf >/dev/null; then
    hf download "$DRAFT_REPO" --local-dir "$DRAFT_DIR"
  else
    docker run --rm -v "$DRAFT_DIR:/out"       -e HF_TOKEN="${HF_TOKEN:-}"       "$IMAGE" python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('$DRAFT_REPO', local_dir='/out')
"
  fi
fi
[ -f "$DRAFT_DIR/config.json" ] || die "drafter checkpoint incomplete after download"
python3 scripts/verify_model.py "$DRAFT_DIR" --min-gib 1 --name drafter
ok "drafter checkpoint ready at $DRAFT_DIR"

# ---------- 4. launch ----------
step "4/6 Launch"
if [ "$(docker ps -q -f name=^${CONTAINER_NAME}$)" ]; then
  if [ "$RESTART" = "1" ]; then
    # ./start.sh restart = stop + remove + relaunch with the CURRENT .env
    # (parity with the MiMo kit 10/6 fix: documented behavior, actually works).
    warn "restart: stopping current container"
    docker stop -t "${STOP_GRACE_S:-30}" "$CONTAINER_NAME" >/dev/null
    docker rm "$CONTAINER_NAME" >/dev/null
    ok "stopped; relaunching below with current settings"
  else
    warn "already running; use ./start.sh restart to apply new settings"
    exit 0
  fi
fi

# GPU launch lock (house rule: flock /tmp/gpu.lock around launches). Fail-fast
# (-n): an operator is driving; silently queueing a 10-minute load is worse
# than refusing.
exec 9>/tmp/gpu.lock
if ! flock -n 9; then
  die "GPU launch lock held (/tmp/gpu.lock) - another launch is in flight" 6
fi
ok "gpu.lock acquired"

# Serve args. Mirrors the model card's DGX Spark Quick Start with the env
# knobs above; JSON quotes inside single-quoted array literals are literal.
ARGS=(
  --model /models/main
  --port "$PORT"
  --served-model-name "$SERVED_NAME"
  --trust-remote-code
  --gpu-memory-utilization "$GPU_MEM_UTIL"
  --max-model-len "$MAX_MODEL_LEN"
  --max-num-batched-tokens "$MAX_BATCHED_TOKENS"
  --max-num-seqs "$MAX_SEQS"
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder
  --reasoning-parser nemotron_v3
  --mamba-backend flashinfer
  --mamba-ssm-cache-dtype float16
  --enable-mamba-cache-stochastic-rounding
  --mamba-cache-philox-rounds 5
  --enable-mamba-shared-prefix-checkpoint
  --video-pruning-rate 0.5
  --media-io-kwargs '{"video":{"fps":2,"num_frames":256}}'
  --block-size 64
  --prefix-match-unit 64
)
if [ "$SPEC_TOKENS" -gt 0 ]; then
  SPEC_JSON=$(printf '{"model":"/models/draft","method":"dflash","num_speculative_tokens":%s}' "$SPEC_TOKENS")
  ARGS+=(--speculative-config "$SPEC_JSON")
  info "LiLiCorr drafting: dflash x${SPEC_TOKENS} slots"
else
  warn "SPEC_TOKENS=0: draft OFF (baseline lane - expect ~35-40 tok/s ceiling on 12B active)"
fi

# Reachability decided HERE by -p host-bind (MiMo audit: HOST_BIND was a
# fictional variable while docker -p published 0.0.0.0). Container-side bind is
# always 0.0.0.0; the host-side -p is the single source of truth, and the
# auth guard in step 1 checked this exact HOST/API_KEY pair.
#
# Publish/listen 1:1 (10/16 first-flight lesson): vLLM binds its own port-8000
# default INSIDE the container unless --port is passed; docker -p forwards
# only. Published 8895 + uvicorn-8000 = /health 000 for the whole wait, hence
# --port "$PORT" in the args below.
ENVARGS=(-e HF_TOKEN="${HF_TOKEN:-}")
if [ -n "$API_KEY" ]; then
  # vLLM OpenAI server reads VLLM_API_KEY for bearer auth.
  ENVARGS+=(-e VLLM_API_KEY="$API_KEY")
fi

docker run -d --name "$CONTAINER_NAME" \
  --gpus all \
  --ipc=host \
  --shm-size 4g \
  -p "${HOST}:${PORT}:${PORT}" \
  -v "$MAIN_DIR:/models/main:ro" \
  -v "$DRAFT_DIR:/models/draft:ro" \
  -v "$VLLM_CACHE_DIR:/root/.cache/vllm" \
  "${ENVARGS[@]}" \
  --restart unless-stopped \
  "$IMAGE" "${ARGS[@]}" >/dev/null
ok "container started (compile cache persists at $VLLM_CACHE_DIR)"

# ---------- 5. health + smoke ----------
step "5/6 Health + smoke test"
ELAPSED=0
while true; do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo 000)
  if [ "$HTTP" = "200" ]; then ok "healthy after ${ELAPSED}s"; break; fi
  # Dead-container detection (lesson: a --restart loop from a bad config used
  # to stall the full timeout before any logs appeared).
  STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo gone)
  if [ "$STATUS" != "running" ] && [ "$ELAPSED" -gt 30 ]; then
    docker logs --tail 40 "$CONTAINER_NAME" 2>&1 || true
    die "container status: $STATUS (not running) after ${ELAPSED}s - logs above" 7
  fi
  if [ "$ELAPSED" -ge "$HEALTH_TIMEOUT" ]; then
    docker logs --tail 40 "$CONTAINER_NAME"; die "health timeout after ${HEALTH_TIMEOUT}s (first launch compiles mamba kernels - see runbook)" 7
  fi
  sleep 15; ELAPSED=$((ELAPSED+15))
  # The long first-start phases (70 GiB weights + mamba/triton compiles +
  # CUDA-graph capture) made the wait a blind 15s tick (1815s with zero
  # signal on 10/16). Every minute, surface the container's last log line so
  # stage progression (Loading weights -> compiling -> graph capture -> app
  # start) is visible in the waiting process instead of a second pane.
  if [ $((ELAPSED % 60)) -eq 0 ]; then
    TAILLN=$(docker logs --tail 3 "$CONTAINER_NAME" 2>/dev/null | tr -d '\r' | tail -1 | cut -c1-110)
    printf '  ...loading %ds   last log: %s\n' "$ELAPSED" "${TAILLN:-<no log yet>}"
  else
    printf '  ...loading %ds\n' "$ELAPSED"
  fi
done

AUTH=()
if [ -n "$API_KEY" ]; then
  # REAL key on the wire (a redacted placeholder here would 401 the smoke).
  AUTH=(-H "Authorization: Bearer ${API_KEY}")
fi
# Discovery, never invention (lesson: an invented id 404s the smoke even with
# a healthy server).
MODELS_JSON=$(curl -s "http://127.0.0.1:${PORT}/v1/models" "${AUTH[@]}")
MODEL_ID=$(printf '%s' "$MODELS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || true)
if [ -z "$MODEL_ID" ]; then
  printf '%s' "$MODELS_JSON" | head -c 400; echo
  die "could not read /v1/models - cannot determine model id for smoke test" 7
fi
info "serving model id: $MODEL_ID"
if [ "$MODEL_ID" != "$SERVED_NAME" ]; then
  warn "served id '$MODEL_ID' differs from SERVED_NAME '$SERVED_NAME' (using discovered id)"
fi

# Smoke asks for the exact string with thinking OFF (Nemotron is a reasoning
# model: on a small budget the whole answer can be reasoning, with null
# content - the Mia sanity lesson).
SMOKE_BODY=$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: HALCERION-KIT-OK"}],"max_tokens":400,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' "$MODEL_ID")
RESP=$(curl -s "http://127.0.0.1:${PORT}/v1/chat/completions" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d "$SMOKE_BODY")
echo "$RESP" | grep -q "HALCERION-KIT-OK" || { echo "$RESP" | head -c 600; die "smoke test failed" 7; }
ok "smoke test passed"

# ---------- banner ----------
# Box glyphs via printf \uXXXX only (heredocs never process escapes). IP via
# the kernel route source (iproute2 is universal; Util-linux hostname -I is
# not, and Arch rejects it while Ubuntu accepts it).
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
[ -z "$IP" ] && IP=$(hostname -I 2>/dev/null | awk '{print $1}')
SPECW="dflash x${SPEC_TOKENS} (LiLiCorr)"
[ "$SPEC_TOKENS" = "0" ] && SPECW="OFF"
BAR=$(printf '\u2550%.0s' $(seq 1 54))
printf '\n'
printf '  \u2554%s\u2557\n' "$BAR"
printf '  \u2551 %-*.*s \u2551\n' 52 52 "Nemotron 3.5 Super VL is LIVE"
# Banner honesty (10/16): the banner printed the box IP even when the bind
# was loopback-only - the operator got an unreachable URL labeled as live.
if [ "$HOST" = "127.0.0.1" ]; then
  printf '  \u2551 %-*.*s \u2551\n' 52 52 "endpoint:  http://127.0.0.1:${PORT}/v1 [loopback]"
  printf '  \u2551 %-*.*s \u2551\n' 52 52 "widen: HOST=0.0.0.0 + API_KEY in .env, restart"
else
  printf '  \u2551 %-*.*s \u2551\n' 52 52 "endpoint:  http://${IP}:${PORT}/v1"
fi
printf '  \u2551 %-*.*s \u2551\n' 52 52 "model:     ${MODEL_ID}"
printf '  \u2551 %-*.*s \u2551\n' 52 52 "draft:     ${SPECW}   seqs: ${MAX_SEQS}   ctx: ${MAX_MODEL_LEN}"
printf '  \u2551 %-*.*s \u2551\n' 52 52 "pool util: ${GPU_MEM_UTIL}   container: ${CONTAINER_NAME}"
if [ "${AUTH_OPEN:-0}" = "1" ]; then
  printf '  \u2551 %-*.*s \u2551\n' 52 52 "auth:      NONE (open on ${IP} + tailnet)"
else
  printf '  \u2551 %-*.*s \u2551\n' 52 52 "auth:      API key (Authorization: Bearer)"
fi
printf '  \u255a%s\u255d\n' "$BAR"
echo "  ./stop.sh stops it.  tools/bench.py measures it (auto-discovers \"$MODEL_ID\")."

# FOREGROUND=1: stay attached following container logs (systemd-unit shape:
# Type=simple wrapper stays alive while the server runs; container keeps
# running across a Ctrl-C of this follower thanks to --restart unless-stopped).
if [ "${FOREGROUND:-0}" = "1" ]; then
  info "FOREGROUND=1: following container logs (Ctrl-C to detach; container keeps running)"
  exec docker logs -f --tail 0 "$CONTAINER_NAME"
fi
