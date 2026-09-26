#!/usr/bin/env bash
# =============================================================================
#  BUILD-TIME ONLY. Installs custom nodes pinned to exact commits.
# =============================================================================
#  Runs inside `docker build` on the internet-connected machine. Anything this
#  script fails to fetch now is something the air-gapped container will try to
#  fetch later — so every failure here is fatal by design (set -e). A broken
#  node must break the build on THIS machine, not surface after the transfer.
# =============================================================================
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/app/ComfyUI}"
NODE_LIST="${NODE_LIST:-/tmp/custom_nodes.txt}"
NODE_DIR="${COMFY_HOME}/custom_nodes"

# Node installers that write model files look at COMFYUI_MODEL_PATH; the
# Dockerfile points it at the defaults tree so the runtime bind mount on
# $COMFY_HOME/models cannot hide what they download. See entrypoint.sh.
export COMFYUI_MODEL_PATH="${COMFYUI_MODEL_PATH:-/opt/comfy-defaults/models}"
mkdir -p "${COMFYUI_MODEL_PATH}" "${NODE_DIR}"

log()  { printf '\n[custom-nodes] %s\n' "$*"; }
fail() { printf '\n[custom-nodes] FATAL: %s\n' "$*" >&2; exit 1; }

installed=0
skipped=0

while IFS= read -r line || [ -n "$line" ]; do
  # Strip comments and surrounding whitespace; skip blanks.
  line="${line%%#*}"
  line="$(printf '%s' "$line" | xargs || true)"
  [ -z "$line" ] && continue

  url="$(printf '%s' "$line" | awk '{print $1}')"
  ref="$(printf '%s' "$line" | awk '{print $2}')"
  name="$(basename "$url" .git)"
  dest="${NODE_DIR}/${name}"

  [ -n "$url" ] || continue
  if [ -z "$ref" ]; then
    fail "$name has no pinned commit in ${NODE_LIST}. Run ./scripts/pin_custom_nodes.sh first.
       An unpinned node makes the image non-reproducible: a later rebuild can
       pick up a different revision with different runtime download behaviour."
  fi

  # A node already present here came from ./custom_nodes_local (installed in
  # the previous build stage). Treat the operator's working copy as canonical.
  if [ -d "$dest" ]; then
    log "SKIPPING ${name} @ ${ref} — superseded by your custom_nodes_local/ copy"
    skipped=$((skipped + 1))
    continue
  fi

  log "installing ${name} @ ${ref}"

  # --filter=blob:none keeps the clone small but still lets us check out an
  # arbitrary historical commit (a --depth 1 clone usually cannot).
  git clone --filter=blob:none "$url" "$dest"
  git -C "$dest" checkout --quiet "$ref" \
    || fail "commit ${ref} not found in ${url}"

  # Drop git metadata: it is dead weight in the shipped image and stops anyone
  # from being tempted to `git pull` on the air-gapped host.
  rm -rf "${dest}/.git"

  if [ -f "${dest}/requirements.txt" ]; then
    log "  pip requirements for ${name}"
    pip install -r "${dest}/requirements.txt"
  fi

  # Node installers commonly fetch models/weights here. That is exactly what we
  # want to happen NOW, while the network is available.
  if [ -f "${dest}/install.py" ]; then
    log "  running install.py for ${name}"
    ( cd "$dest" && python install.py ) \
      || fail "install.py failed for ${name}"
  fi

  installed=$((installed + 1))
done < "${NODE_LIST}"

if [ "$installed" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  fail "no custom nodes installed — is ${NODE_LIST} empty?"
fi

log "installed ${installed} pinned node package(s); ${skipped} superseded by local copies"

ls -1 "${NODE_DIR}"
