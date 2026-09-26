#!/usr/bin/env bash
# =============================================================================
#  INTERNET MACHINE — build, then verify. Does not export (see export_image.sh).
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env found — copying from .env.example"; cp .env.example .env; }
set -a && . ./.env && set +a

IMAGE="${IMAGE_NAME:-comfyui-airgap}:${IMAGE_TAG:-v0.37.0}"

echo "=============================================================="
echo " Building $IMAGE"
echo "   ComfyUI ref : ${COMFYUI_REF:-v0.37.0}"
echo "   CUDA base   : ${CUDA_IMAGE:-nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04}"
echo "   Torch index : ${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"
echo "   Target UID  : ${PUID:-1000}:${PGID:-1000}"
echo "   Expect 30-60 min and ~10-15 GB."
echo "=============================================================="

# Every pin must be resolved before we build.
if grep -vE '^\s*(#|$)' custom_nodes.txt | awk 'NF<2 {exit 1}'; then :; else
  echo "Unpinned nodes found. Resolving..."
  ./scripts/pin_custom_nodes.sh
fi

docker compose -f docker-compose.build.yml build --progress=plain 2>&1 | tee build.log

# Pull the resolved dependency set out of the image so a future rebuild can be
# made byte-comparable and so you have a record of exactly what shipped.
docker run --rm "$IMAGE" cat /opt/comfy-defaults/meta/requirements.lock.txt > requirements.lock.txt
docker run --rm "$IMAGE" cat /opt/comfy-defaults/meta/comfyui.sha > comfyui.sha

echo
echo "Built $IMAGE  ($(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1024/1024/1024}'))"
echo "Locked $(wc -l < requirements.lock.txt) python packages -> requirements.lock.txt"
echo
echo "NEXT — do not skip: ./scripts/verify_offline.sh"
