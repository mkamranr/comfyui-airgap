#!/usr/bin/env bash
# =============================================================================
#  BUILD-TIME ONLY. Forces down assets that custom nodes fetch LAZILY.
# =============================================================================
#  This is the step most air-gapped ComfyUI setups miss.
#
#  `install.py` downloads (Impact Pack's SAM, Impact Subpack's YOLO models)
#  happen during the build and are caught automatically. But some nodes
#  download nothing until a node is actually EXECUTED for the first time:
#
#    * comfyui_controlnet_aux       -> annotator checkpoints from HuggingFace
#    * ComfyUI-Frame-Interpolation  -> VFI checkpoints from GitHub releases
#
#  On a connected machine you never notice. On the air-gapped box those nodes
#  fail at the moment someone tries to use them, long after the transfer.
#  So we pull them here, while the network still exists.
# =============================================================================
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/app/ComfyUI}"
PREWARM_CONTROLNET_AUX="${PREWARM_CONTROLNET_AUX:-1}"

log() { printf '\n[prewarm] %s\n' "$*"; }

# =============================================================================
#  comfyui_controlnet_aux annotator checkpoints
# =============================================================================
#  Stored under the node's own ckpts/ directory, which lives INSIDE the image
#  and is not bind-mounted -- so unlike models/ it is safe from shadowing.
#
#  The node resolves files via huggingface_hub with cache_dir=<node>/ckpts, so
#  we prime that exact cache layout with snapshot_download(cache_dir=...).
#
#  lllyasviel/Annotators covers the large majority of preprocessors (canny, hed,
#  midas, openpose, lineart, normalbae, ...). A preprocessor that pulls from a
#  different repo needs its repo id added to PREWARM_HF_REPOS; the --network
#  none test in scripts/verify_offline.sh is how you find them.
CN_AUX_DIR="${COMFY_HOME}/custom_nodes/comfyui_controlnet_aux"
PREWARM_HF_REPOS="${PREWARM_HF_REPOS:-lllyasviel/Annotators}"

if [ "${PREWARM_CONTROLNET_AUX}" = "1" ] && [ -d "${CN_AUX_DIR}" ]; then
  CKPTS="${CN_AUX_DIR}/ckpts"
  mkdir -p "${CKPTS}"
  for repo in ${PREWARM_HF_REPOS}; do
    log "controlnet_aux: downloading ${repo} -> ${CKPTS} (several GB)"
    python - "$repo" "$CKPTS" <<'PY'
import sys
from huggingface_hub import snapshot_download
repo_id, cache_dir = sys.argv[1], sys.argv[2]
print(f"  cached {repo_id} at {snapshot_download(repo_id=repo_id, cache_dir=cache_dir)}")
PY
  done
elif [ ! -d "${CN_AUX_DIR}" ]; then
  log "controlnet_aux not installed — skipping its prewarm"
else
  log "SKIPPED controlnet_aux prewarm (PREWARM_CONTROLNET_AUX=0)"
  log "  ControlNet preprocessor nodes WILL FAIL on the air-gapped host."
fi

# =============================================================================
#  ComfyUI-Frame-Interpolation (VFI) checkpoints
# =============================================================================
#  The node calls load_file_from_github_release(model_type, ckpt_name), which
#  tries a list of GitHub release mirrors and saves to <node>/ckpts/<type>/.
#  We reproduce that here with plain curl rather than importing the node, which
#  would require a live ComfyUI runtime at build time.
#
#  VFI_PREWARM is a space-separated list of "<model_type>:<ckpt_name>" pairs.
#  Model types are the directory names under vfi_models/ (rife, film, cain,
#  amt, gmfss_fortuna, ifrnet, m2m, sepconv, stmfnet, flavr, ...).
#
#  Default covers the two most-used families. Add more if your workflows need
#  them -- an unlisted checkpoint means that node fails offline.
VFI_DIR="${COMFY_HOME}/custom_nodes/ComfyUI-Frame-Interpolation"
VFI_PREWARM="${VFI_PREWARM:-rife:rife47.pth rife:rife49.pth film:film_net_fp32.pt}"

# Mirrors, tried in order — same list the node itself uses.
VFI_BASE_URLS="
https://github.com/styler00dollar/VSGAN-tensorrt-docker/releases/download/models/
https://github.com/Fannovel16/ComfyUI-Frame-Interpolation/releases/download/models/
https://github.com/dajes/frame-interpolation-pytorch/releases/download/v1.0.0/
"

if [ -d "${VFI_DIR}" ] && [ -n "${VFI_PREWARM}" ]; then
  for pair in ${VFI_PREWARM}; do
    mtype="${pair%%:*}"
    ckpt="${pair#*:}"
    if [ -z "$mtype" ] || [ -z "$ckpt" ] || [ "$mtype" = "$ckpt" ]; then
      echo "[prewarm] FATAL: malformed VFI_PREWARM entry '${pair}' (want type:file)" >&2
      exit 1
    fi

    out_dir="${VFI_DIR}/ckpts/${mtype}"
    out="${out_dir}/${ckpt}"
    mkdir -p "$out_dir"
    [ -s "$out" ] && { log "VFI: ${mtype}/${ckpt} already present"; continue; }

    got=0
    for base in ${VFI_BASE_URLS}; do
      log "VFI: trying ${base}${ckpt}"
      if curl -fsSL --retry 3 --retry-delay 2 -o "${out}.part" "${base}${ckpt}"; then
        mv "${out}.part" "$out"; got=1
        log "  saved -> ${out} ($(du -h "$out" | cut -f1))"
        break
      fi
      rm -f "${out}.part"
    done

    if [ "$got" -ne 1 ]; then
      echo "[prewarm] FATAL: could not fetch VFI checkpoint '${ckpt}' for type '${mtype}'." >&2
      echo "          Tried every mirror. Check the filename against" >&2
      echo "          vfi_models/${mtype}/__init__.py in the node repo." >&2
      exit 1
    fi
  done
elif [ ! -d "${VFI_DIR}" ]; then
  log "ComfyUI-Frame-Interpolation not installed — skipping VFI prewarm"
else
  log "SKIPPED VFI prewarm (VFI_PREWARM empty) — interpolation nodes will fail offline"
fi

# =============================================================================
#  Audit trail — makes the build log show exactly what shipped.
# =============================================================================
log "baked model assets in the defaults tree:"
find /opt/comfy-defaults/models -type f -printf '  %-70p %10s bytes\n' 2>/dev/null || true

for d in "${CN_AUX_DIR}/ckpts" "${VFI_DIR}/ckpts"; do
  [ -d "$d" ] && log "$(basename "$(dirname "$d")") ckpts: $(du -sh "$d" 2>/dev/null | cut -f1)"
done
