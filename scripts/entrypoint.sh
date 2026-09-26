#!/usr/bin/env bash
# =============================================================================
#  Runtime entrypoint — STRICTLY LOCAL. Makes no network calls of any kind.
# =============================================================================
#  Purpose: a bind mount replaces whatever the image had at that path. Mounting
#  the host's ./models over /app/ComfyUI/models hides every file we baked in
#  there at build time (e.g. Impact Pack's SAM checkpoint), and mounting ./user
#  hides ComfyUI-Manager's offline config. Both would surface as confusing
#  runtime failures on the air-gapped box.
#
#  So: defaults live in $COMFY_DEFAULTS (never mounted over) and are copied into
#  the mounted tree here, on every start, without clobbering anything the
#  operator has put there. `cp -rn` is what makes this safe and idempotent.
# =============================================================================
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/app/ComfyUI}"
COMFY_DEFAULTS="${COMFY_DEFAULTS:-/opt/comfy-defaults}"
COMFY_META="${COMFY_META:-${COMFY_DEFAULTS}/meta}"

log() { printf '[entrypoint] %s\n' "$*"; }

# --- 1. Ensure ComfyUI's expected model tree exists inside the mount ---------
# A freshly-rsynced host ./models folder is often missing subdirectories, and
# ComfyUI logs confusing "path does not exist" warnings for each one.
MODEL_SUBDIRS=(
  checkpoints clip clip_vision configs controlnet diffusers diffusion_models
  embeddings gligen hypernetworks loras onnx photomaker sams style_models
  text_encoders unet upscale_models vae vae_approx
  ultralytics ultralytics/bbox ultralytics/segm
)
for d in "${MODEL_SUBDIRS[@]}"; do
  mkdir -p "${COMFY_HOME}/models/${d}"
done
mkdir -p "${COMFY_HOME}/input" "${COMFY_HOME}/output" \
         "${COMFY_HOME}/user" "${COMFY_HOME}/temp"

# --- 2. Seed baked-in defaults into the mounted trees (never overwrite) ------
if [ -d "${COMFY_DEFAULTS}/models" ]; then
  log "seeding node-provided models (no-clobber)"
  cp -rn "${COMFY_DEFAULTS}/models/." "${COMFY_HOME}/models/" 2>/dev/null || true
fi
if [ -d "${COMFY_DEFAULTS}/user" ]; then
  log "seeding default user config (no-clobber)"
  cp -rn "${COMFY_DEFAULTS}/user/." "${COMFY_HOME}/user/" 2>/dev/null || true
fi

# --- 3. Re-assert ComfyUI-Manager offline mode ------------------------------
# Deliberately stronger than the no-clobber seed above: a config.ini carried
# over from a connected install will still say network_mode = public, and
# Manager will then stall at startup trying to reach its node database. On an
# air-gapped host that is never what we want, so we correct it in place.
MGR_DIR="${COMFY_HOME}/user/__manager"
MGR_CFG="${MGR_DIR}/config.ini"
mkdir -p "${MGR_DIR}"
if ! grep -qE '^[[:space:]]*network_mode[[:space:]]*=[[:space:]]*offline' "${MGR_CFG}" 2>/dev/null; then
  log "forcing ComfyUI-Manager into offline network_mode"
  cp -f "${COMFY_DEFAULTS}/user/__manager/config.ini" "${MGR_CFG}"
fi

# --- 4. Fail loudly if the GPU was requested but is not visible -------------
# Without this the container starts happily and every generation silently runs
# on CPU at ~1/50th speed, which is easy to miss for hours.
if [ "${COMFY_REQUIRE_GPU:-1}" = "1" ]; then
  if ! python -c "import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    log "WARNING: torch.cuda.is_available() is False — running on CPU."
    log "         Check the NVIDIA Container Toolkit and the compose 'devices' block."
    log "         Set COMFY_REQUIRE_GPU=0 to silence this."
  else
    log "GPU OK: $(python -c 'import torch; print(torch.cuda.get_device_name(0))')"
  fi
fi

log "starting ComfyUI ($(cut -c1-12 "${COMFY_META}/comfyui.sha" 2>/dev/null || echo unknown))"
exec "$@"
