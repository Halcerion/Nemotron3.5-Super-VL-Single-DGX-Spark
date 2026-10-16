#!/usr/bin/env bash
# stop.sh — stop the halcerion nemotron container and free the GPU memory.
set -euo pipefail
cd "$(dirname "$0")"
# .env supplies CONTAINER_NAME here (MiMo lesson #9: without sourcing it,
# probes used the script's own fallback whenever .env changed it).
if [ -f .env ]; then
  set -a; source .env; set +a
fi
NAME="${CONTAINER_NAME:-halcerion-nemotron35-spark}"

if ! docker ps -q -f name=^${NAME}$ | grep -q .; then
  echo "[halcerion-kit] not running"
  exit 0
fi

# In-flight handling: vLLM's /health has no busy/in-flight field (same as
# TabbyAPI — nothing honest to probe). docker stop sends SIGTERM: vLLM's
# uvicorn stops accepting new requests and drains or gracefully cuts open
# streams during the grace window, then SIGKILL. Run long generations from
# tmux so a stop is always a deliberate act; extend STOP_GRACE_S in .env.
docker stop -t "${STOP_GRACE_S:-30}" "$NAME" >/dev/null || true
docker rm "$NAME" >/dev/null
echo "[halcerion-kit] stopped; GPU memory freed (verify: free -h on the spark)"
