# syntax=docker/dockerfile:1.7
# =============================================================================
#  ComfyUI — air-gapped image
# =============================================================================
#  Built ONCE on an internet-connected machine. Everything ComfyUI and its
#  custom nodes need at runtime is baked in, so the container makes ZERO
#  outbound connections on the target machine.
#
#  Build:  ./scripts/build.sh
#  Verify: ./scripts/verify_offline.sh      <-- runs it under --network none
#  Export: ./scripts/export_image.sh
# =============================================================================

ARG CUDA_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
FROM ${CUDA_IMAGE}

# --- Build-time knobs -------------------------------------------------------
# COMFYUI_REF : git tag/branch/sha of Comfy-Org/ComfyUI to pin to.
# TORCH_INDEX : PyTorch wheel index. MUST match CUDA_IMAGE above and be
#               supported by the driver on the AIR-GAPPED host (see README).
# PUID/PGID   : must match the owner of the bind-mounted dirs on the TARGET.
ARG COMFYUI_REF=v0.37.0
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu128
ARG PUID=1000
ARG PGID=1000
ARG PREWARM_CONTROLNET_AUX=1
# Space-separated "<model_type>:<ckpt_name>" pairs for ComfyUI-Frame-Interpolation.
ARG VFI_PREWARM="rife:rife47.pth rife:rife49.pth film:film_net_fp32.pt"
# 1 = a local node that fails to install aborts the build; 0 = warn and continue.
ARG LOCAL_NODES_STRICT=1

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    COMFY_HOME=/app/ComfyUI \
    COMFY_DEFAULTS=/opt/comfy-defaults \
    COMFY_META=/opt/comfy-defaults/meta

# -----------------------------------------------------------------------------
# 1. OS packages (root)
# -----------------------------------------------------------------------------
# libgl1 + libglib2.0-0 : OpenCV, pulled in by controlnet_aux and Impact Pack
# ffmpeg                : VideoHelperSuite
# build-essential       : some custom nodes compile C extensions on install
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-dev \
      git git-lfs ca-certificates curl \
      build-essential libgl1 libglib2.0-0 ffmpeg \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. Unprivileged user, created BEFORE any heavy content exists.
# -----------------------------------------------------------------------------
# Ordering matters for image size: a `chown -R` applied after ~10GB of installs
# rewrites every file into a new layer and very nearly doubles the image. By
# creating the user first and building everything as that user, no recursive
# chown is ever needed.
#
# ubuntu:24.04 ships a stock `ubuntu` account already holding UID 1000, so a
# plain `useradd -u 1000` fails. Reclaim the UID/GID first.
RUN set -eux; \
    if getent passwd "${PUID}" >/dev/null; then \
      userdel -r "$(getent passwd "${PUID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    if ! getent group "${PGID}" >/dev/null; then groupadd -g "${PGID}" comfy; fi; \
    useradd -m -u "${PUID}" -g "${PGID}" -s /bin/bash comfy; \
    mkdir -p /app/cache/huggingface /app/cache/torch \
             "${VIRTUAL_ENV}" "${COMFY_DEFAULTS}/models" \
             "${COMFY_DEFAULTS}/user/__manager" "${COMFY_META}"; \
    chown -R "${PUID}:${PGID}" /app "${VIRTUAL_ENV}" "${COMFY_DEFAULTS}"

USER ${PUID}:${PGID}

# Ubuntu 24.04 marks its system Python PEP-668 "externally managed", so pip
# refuses to install into it. A venv is required here, not a style choice.
RUN python3 -m venv "$VIRTUAL_ENV" \
    && pip install --upgrade pip wheel setuptools

# -----------------------------------------------------------------------------
# 3. ComfyUI, pinned to a release tag.
# -----------------------------------------------------------------------------
RUN git clone --depth 1 --branch "${COMFYUI_REF}" \
      https://github.com/Comfy-Org/ComfyUI.git "${COMFY_HOME}" \
    && git -C "${COMFY_HOME}" rev-parse HEAD > "${COMFY_META}/comfyui.sha"

# -----------------------------------------------------------------------------
# 4. PyTorch FIRST, from the CUDA wheel index.
# -----------------------------------------------------------------------------
# Order matters: ComfyUI's requirements.txt lists a bare `torch`, which would
# otherwise resolve to the CPU-only build from PyPI and silently produce an
# image where torch.cuda.is_available() is False.
RUN pip install --index-url "${TORCH_INDEX}" torch torchvision torchaudio \
    && python -c "import torch; print('torch', torch.__version__, '| cuda build', torch.version.cuda)"

# -----------------------------------------------------------------------------
# 5. ComfyUI's own requirements.
# -----------------------------------------------------------------------------
# The web frontend, workflow templates and embedded docs are ordinary pip
# packages now (comfyui-frontend-package / -workflow-templates /
# -embedded-docs), so they are installed here at build time and there is no
# frontend download at startup. That is why --front-end-root is not needed.
RUN pip install -r "${COMFY_HOME}/requirements.txt"

# -----------------------------------------------------------------------------
# 6. Custom nodes, each pinned to an exact commit.
# -----------------------------------------------------------------------------
# COMFYUI_MODEL_PATH points node installers (notably ComfyUI-Impact-Pack, which
# downloads sam_vit_b_01ec64.pth) at the DEFAULTS tree rather than
# $COMFY_HOME/models -- the latter is shadowed by the models bind mount at
# runtime, which would make the baked file vanish. entrypoint.sh seeds it back.
# 6a. Nodes you already have on disk, from ./custom_nodes_local (may be empty).
#     Installed FIRST so that a local copy wins over a same-named pinned entry,
#     which install_custom_nodes.sh then skips with a warning.
COPY --chown=${PUID}:${PGID} scripts/install_local_nodes.sh /tmp/
COPY --chown=${PUID}:${PGID} custom_nodes_local /tmp/custom_nodes_local
RUN COMFYUI_MODEL_PATH="${COMFY_DEFAULTS}/models" \
    LOCAL_NODES_STRICT="${LOCAL_NODES_STRICT}" \
    bash /tmp/install_local_nodes.sh

# 6b. Git-pinned nodes from custom_nodes.txt.
COPY --chown=${PUID}:${PGID} custom_nodes.txt /tmp/custom_nodes.txt
COPY --chown=${PUID}:${PGID} scripts/install_custom_nodes.sh /tmp/
RUN COMFYUI_MODEL_PATH="${COMFY_DEFAULTS}/models" \
    bash /tmp/install_custom_nodes.sh

# -----------------------------------------------------------------------------
# 7. Pre-warm assets that custom nodes fetch LAZILY on first execution.
# -----------------------------------------------------------------------------
# These are invisible during a normal build+run test on a connected machine and
# only fail once the box is air-gapped, so they must be forced down now.
COPY --chown=${PUID}:${PGID} scripts/prewarm_models.sh /tmp/
RUN PREWARM_CONTROLNET_AUX="${PREWARM_CONTROLNET_AUX}" \
    VFI_PREWARM="${VFI_PREWARM}" \
    bash /tmp/prewarm_models.sh

# -----------------------------------------------------------------------------
# 8. Freeze the fully-resolved environment so a rebuild is reproducible.
# -----------------------------------------------------------------------------
RUN pip freeze > "${COMFY_META}/requirements.lock.txt"

# -----------------------------------------------------------------------------
# 9. ComfyUI-Manager offline config, staged in the DEFAULTS tree.
# -----------------------------------------------------------------------------
# Manager reads <user-dir>/__manager/config.ini, and ./user is bind-mounted at
# runtime, so writing it directly would be shadowed. entrypoint.sh seeds it.
COPY --chown=${PUID}:${PGID} config/manager-config.ini ${COMFY_DEFAULTS}/user/__manager/config.ini

# -----------------------------------------------------------------------------
# 10. Offline switches.
# -----------------------------------------------------------------------------
# Tripwires, not restrictions: if any library still tries to reach the network
# it now fails instantly with a readable error, instead of blocking on a
# 60-second DNS timeout that is indistinguishable from a hung container.
# Declared AFTER every step above, all of which legitimately need the network.
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_DATASETS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    HF_HUB_DISABLE_IMPLICIT_TOKEN=1 \
    HF_HOME=/app/cache/huggingface \
    TORCH_HOME=/app/cache/torch \
    PIP_NO_INDEX=1 \
    DO_NOT_TRACK=1 \
    GRADIO_ANALYTICS_ENABLED=False

COPY --chown=${PUID}:${PGID} scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR ${COMFY_HOME}
EXPOSE 8188

# --disable-api-nodes does double duty: it skips the API node packs AND, per
# comfy/cli_args.py, "prevents the frontend from communicating with the
# internet". Removing it causes outbound calls from the browser UI.
ENV COMFY_ARGS="--listen 0.0.0.0 --port 8188 --disable-api-nodes"

# Generous start-period: first boot seeds directories and imports every node.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8188/system_stats || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sh", "-c", "exec python main.py ${COMFY_ARGS}"]
