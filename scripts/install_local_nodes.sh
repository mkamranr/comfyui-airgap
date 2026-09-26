#!/usr/bin/env bash
# =============================================================================
#  BUILD-TIME ONLY. Installs custom nodes you already have on disk.
# =============================================================================
#  Source: ./custom_nodes_local/ in the build context. Drop (or rsync) the
#  contents of an existing ComfyUI custom_nodes directory in there and every
#  node folder is baked into the image alongside the git-pinned ones.
#
#  This runs BEFORE install_custom_nodes.sh. Anything present here therefore
#  WINS over a same-named entry in custom_nodes.txt, which skips it with a
#  warning -- your working copy is assumed to be the one you want.
#
#  Failures are collected and reported together at the end rather than aborting
#  on the first one: an inherited custom_nodes folder often has several stale
#  nodes, and finding them one build at a time is painful. Set
#  LOCAL_NODES_STRICT=0 to downgrade failures to warnings.
# =============================================================================
set -uo pipefail

COMFY_HOME="${COMFY_HOME:-/app/ComfyUI}"
SRC="${LOCAL_NODES_SRC:-/tmp/custom_nodes_local}"
DEST="${COMFY_HOME}/custom_nodes"
STRICT="${LOCAL_NODES_STRICT:-1}"

# Node installers that write model files must land in the defaults tree, not in
# $COMFY_HOME/models, which the runtime bind mount shadows. See entrypoint.sh.
export COMFYUI_MODEL_PATH="${COMFYUI_MODEL_PATH:-/opt/comfy-defaults/models}"
mkdir -p "$DEST" "$COMFYUI_MODEL_PATH"

log() { printf '\n[local-nodes] %s\n' "$*"; }

if [ ! -d "$SRC" ]; then
  log "no ./custom_nodes_local directory in the build context — nothing to do"
  exit 0
fi

installed=0
skipped=0
failures=()

shopt -s nullglob
for path in "$SRC"/*; do
  name="$(basename "$path")"

  case "$name" in
    .gitkeep|README.md|.DS_Store|__pycache__) continue ;;
    # ComfyUI-Manager disables a node by renaming it; honour that.
    *.disabled)
      log "skipping disabled node: ${name}"; skipped=$((skipped+1)); continue ;;
  esac

  # Loose files ComfyUI itself ships in custom_nodes (e.g. *.py.example).
  if [ ! -d "$path" ]; then
    cp -f "$path" "$DEST/" && log "copied file: ${name}"
    continue
  fi

  log "installing local node: ${name}"
  rm -rf "${DEST:?}/${name}"
  if ! cp -r "$path" "${DEST}/${name}"; then
    failures+=("${name}: copy failed"); continue
  fi

  # Drop dead weight and anything that tempts a `git pull` on the air-gapped host.
  rm -rf "${DEST}/${name}/.git" "${DEST}/${name}/.github"
  find "${DEST}/${name}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find "${DEST}/${name}" -name '*.pyc' -delete 2>/dev/null || true

  if [ -f "${DEST}/${name}/requirements.txt" ]; then
    log "  pip requirements for ${name}"
    pip install -r "${DEST}/${name}/requirements.txt" \
      || failures+=("${name}: pip install -r requirements.txt failed")
  fi

  # This is where a node fetches its models — exactly what we want happening
  # now, while the build machine still has a network.
  if [ -f "${DEST}/${name}/install.py" ]; then
    log "  running install.py for ${name}"
    ( cd "${DEST}/${name}" && python install.py ) \
      || failures+=("${name}: install.py failed")
  fi

  installed=$((installed+1))
done

log "local nodes: ${installed} installed, ${skipped} skipped, ${#failures[@]} failed"

if [ "${#failures[@]}" -gt 0 ]; then
  printf '\n[local-nodes] FAILURES:\n'
  for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
  printf '\n'
  if [ "$STRICT" = "1" ]; then
    echo "[local-nodes] FATAL: the above local nodes did not install cleanly." >&2
    echo "  A node that fails here is a node that will be broken (or will try to" >&2
    echo "  reach the network) on the air-gapped host. Remove it from" >&2
    echo "  custom_nodes_local/, or rebuild with LOCAL_NODES_STRICT=0 to accept" >&2
    echo "  it as-is." >&2
    exit 1
  fi
  echo "[local-nodes] WARNING: continuing anyway (LOCAL_NODES_STRICT=0)." >&2
fi

exit 0
