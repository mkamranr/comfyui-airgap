#!/usr/bin/env bash
# =============================================================================
#  AIR-GAPPED MACHINE — verify, load, and prepare to run.
# =============================================================================
#  Usage:  ./scripts/load_image.sh /media/usb/comfyui-airgap-v0.37.0.tar.zst
#
#  This does NOT build anything. `docker load` restores the image exactly as it
#  was built on the internet machine.
# =============================================================================
set -euo pipefail

ARCHIVE="${1:-}"
[ -n "$ARCHIVE" ] || { echo "Usage: $0 <path-to-image-archive>"; exit 1; }
[ -f "$ARCHIVE" ] || { echo "FATAL: $ARCHIVE not found"; exit 1; }

cd "$(dirname "$0")/.."

# --- 1. Integrity first -----------------------------------------------------
# A truncated USB copy surfaces as an obscure layer error deep inside
# `docker load`; checking here turns that into a clear message.
SUMS="$(dirname "$ARCHIVE")/SHA256SUMS"
if [ -f "$SUMS" ]; then
  echo ">>> Verifying checksum..."
  ( cd "$(dirname "$ARCHIVE")" && sha256sum -c --ignore-missing SHA256SUMS ) \
    || { echo "FATAL: checksum mismatch — re-copy the file."; exit 1; }
else
  echo ">>> WARNING: no SHA256SUMS beside the archive; skipping integrity check."
fi

# --- 2. Load ----------------------------------------------------------------
echo ">>> Loading image (no network required)..."
case "$ARCHIVE" in
  *.tar.zst) zstd -dc "$ARCHIVE" | docker load ;;
  *.tar.gz)  gzip -dc "$ARCHIVE" | docker load ;;
  *.tar)     docker load -i "$ARCHIVE" ;;
  *)         echo "FATAL: unrecognised archive type"; exit 1 ;;
esac

# --- 3. Local setup ---------------------------------------------------------
if [ ! -f .env ]; then
  echo ">>> Creating .env with this host's UID/GID"
  cp .env.example .env
  sed -i "s/^PUID=.*/PUID=$(id -u)/; s/^PGID=.*/PGID=$(id -g)/" .env
fi

mkdir -p models input output user
echo ">>> Fixing bind-mount ownership to $(id -u):$(id -g)"
chown -R "$(id -u):$(id -g)" models input output user 2>/dev/null \
  || sudo chown -R "$(id -u):$(id -g)" models input output user

echo
echo "=============================================================="
docker images | head -1
docker images | grep comfyui-airgap || true
echo "=============================================================="
echo
echo "Next:"
echo "  1. Put model files in ./models/checkpoints (etc.)"
echo "  2. docker compose up -d"
echo "  3. docker compose logs -f"
echo "  4. Open http://\$(hostname -I | awk '{print \$1}'):8188"
