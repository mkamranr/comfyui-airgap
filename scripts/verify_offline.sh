#!/usr/bin/env bash
# =============================================================================
#  Prove the image works with NO NETWORK — run on the internet machine.
# =============================================================================
#  `--network none` gives the container a loopback interface and nothing else:
#  no DNS, no default route, no host network access. That is a faithful
#  simulation of the air-gapped server.
#
#  Catching a missing dependency here costs a few minutes. Catching it after
#  the image is on a USB stick behind the air gap costs a full round trip.
#  Do not skip this step, and re-run it after ANY change to custom_nodes.txt.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

IMAGE="${IMAGE_NAME:-comfyui-airgap}:${IMAGE_TAG:-v0.37.0}"
NAME=comfy-airgap-verify
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$*"; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "FATAL: image $IMAGE not found. Build it first:"
  echo "  docker compose -f docker-compose.build.yml build"
  exit 1
}

info "Verifying $IMAGE with --network none"

# --- 1. Torch + CUDA, no network -------------------------------------------
info "1/5  PyTorch and CUDA"
if docker run --rm --network none --gpus all "$IMAGE" \
     python -c "import torch,sys; print('torch',torch.__version__,'| cuda',torch.version.cuda,'| available',torch.cuda.is_available()); sys.exit(0 if torch.cuda.is_available() else 1)"; then
  ok "torch imports and sees the GPU without network"
else
  bad "torch cannot see a GPU (check NVIDIA Container Toolkit on THIS machine)"
fi

# --- 2. Boot the full server with no network -------------------------------
info "2/5  Server startup (no network, timeout ${BOOT_TIMEOUT}s)"
docker run -d --name "$NAME" --network none --gpus all --shm-size=8gb "$IMAGE" >/dev/null

booted=0
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
  if docker exec "$NAME" curl -fsS http://127.0.0.1:8188/system_stats >/dev/null 2>&1; then
    booted=1; break
  fi
  if ! docker ps -q --filter "name=^${NAME}$" | grep -q .; then
    bad "container exited during startup"; break
  fi
  sleep 1
done

if [ "$booted" = 1 ]; then
  ok "server answered /system_stats with no network"
else
  bad "server did not come up within ${BOOT_TIMEOUT}s"
fi

# --- 3. Every custom node registered its nodes -----------------------------
info "3/5  Custom node registration"
if [ "$booted" = 1 ]; then
  count=$(docker exec "$NAME" python -c \
    "import json,urllib.request; print(len(json.load(urllib.request.urlopen('http://127.0.0.1:8188/object_info'))))" 2>/dev/null)
  if [ -n "${count:-}" ] && [ "$count" -gt 300 ]; then
    ok "$count node types registered"
  else
    bad "only ${count:-0} node types registered — a custom node failed to import"
  fi
else
  bad "skipped (server never came up)"
fi

# --- 4. No import failures or network errors in the log --------------------
info "4/5  Log scan for failures"
LOGS=$(docker logs "$NAME" 2>&1)
PATTERN='IMPORT FAILED|Traceback|ConnectionError|ConnectTimeout|Max retries exceeded|Temporary failure in name resolution|Failed to establish a new connection|Name or service not known|urlopen error'
if printf '%s' "$LOGS" | grep -qEi "$PATTERN"; then
  bad "network/import errors found:"
  printf '%s' "$LOGS" | grep -Ei "$PATTERN" | head -25 | sed 's/^/        /'
  echo
  echo "        ^ each of these is something the air-gapped host will also hit."
  echo "        Fix by adding the missing asset to scripts/prewarm_models.sh."
else
  ok "no import failures or network errors in the log"
fi

# --- 5. ComfyUI-Manager is actually in offline mode ------------------------
info "5/5  ComfyUI-Manager offline mode"
if docker exec "$NAME" grep -qE '^\s*network_mode\s*=\s*offline' \
     /app/ComfyUI/user/__manager/config.ini 2>/dev/null; then
  ok "Manager config.ini has network_mode = offline"
else
  bad "Manager is NOT in offline mode — it will stall at startup on the target"
fi

# --- Summary ---------------------------------------------------------------
printf '\n\033[1mResult: %d passed, %d failed\033[0m\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\033[32mImage is air-gap ready. Next: ./scripts/export_image.sh\033[0m\n\n'
  exit 0
fi
printf '\033[31mDo NOT transfer this image until the failures above are resolved.\033[0m\n\n'
exit 1
