#!/usr/bin/env bash
# =============================================================================
#  INTERNET MACHINE — export the image (and optionally models) for transfer.
# =============================================================================
#  Refuses to run until verify_offline.sh has passed, so a known-broken image
#  cannot be carried across the air gap.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

IMAGE="${IMAGE_NAME:-comfyui-airgap}:${IMAGE_TAG:-v0.37.0}"
OUT="${OUT_DIR:-./dist}"
BASE="${IMAGE_NAME:-comfyui-airgap}-${IMAGE_TAG:-v0.37.0}"
SPLIT_SIZE="${SPLIT_SIZE:-}"          # e.g. 3900M for a FAT32 stick

mkdir -p "$OUT"

if [ "${SKIP_VERIFY:-0}" != "1" ]; then
  echo ">>> Running offline verification before export..."
  ./scripts/verify_offline.sh || {
    echo
    echo "Verification failed — refusing to export."
    echo "Override with SKIP_VERIFY=1 only if you know exactly why."
    exit 1
  }
fi

# zstd is several times faster than gzip at a similar ratio on a ~12GB image.
if command -v zstd >/dev/null 2>&1; then
  ARCHIVE="$OUT/${BASE}.tar.zst"
  echo ">>> Saving + compressing (zstd) -> $ARCHIVE"
  docker save "$IMAGE" | zstd -T0 -12 -o "$ARCHIVE"
else
  ARCHIVE="$OUT/${BASE}.tar.gz"
  echo ">>> zstd not found, falling back to gzip -> $ARCHIVE"
  docker save "$IMAGE" | gzip -6 > "$ARCHIVE"
fi

# The runbook, compose file and scripts must travel too.
REPO="$OUT/${BASE}-repo.tar.gz"
echo ">>> Packing repo -> $REPO"
tar -czf "$REPO" \
  --exclude='./dist' --exclude='./models' --exclude='./output' \
  --exclude='./input' --exclude='./.git' --exclude='./build.log' \
  Dockerfile docker-compose.yml .env.example custom_nodes.txt \
  requirements.lock.txt comfyui.sha config scripts README.md 2>/dev/null || \
tar -czf "$REPO" Dockerfile docker-compose.yml .env.example custom_nodes.txt config scripts README.md

# Models are bind-mounted, so they are a separate payload.
if [ "${EXPORT_MODELS:-1}" = "1" ] && [ -n "$(find models -type f ! -name '.gitkeep' 2>/dev/null | head -1)" ]; then
  MODELS="$OUT/${BASE}-models.tar"
  echo ">>> Packing models -> $MODELS (weights are already compressed; storing)"
  tar -cf "$MODELS" models/
else
  echo ">>> No models to export (./models is empty) — copy them separately."
fi

# Integrity is not optional across an air gap: a truncated USB write produces a
# corrupt layer that docker load reports in a very unhelpful way.
echo ">>> Checksumming"
( cd "$OUT" && sha256sum ./*.tar.zst ./*.tar.gz ./*.tar 2>/dev/null > SHA256SUMS || true )

if [ -n "$SPLIT_SIZE" ]; then
  echo ">>> Splitting into ${SPLIT_SIZE} chunks (FAT32 has a 4GB file limit)"
  ( cd "$OUT" && split -b "$SPLIT_SIZE" "$(basename "$ARCHIVE")" "$(basename "$ARCHIVE").part-" )
fi

echo
echo "=============================================================="
ls -lh "$OUT"
echo "=============================================================="
echo "Transfer the ENTIRE $OUT directory, SHA256SUMS included."
echo "Then follow 'Phase D' in README.md on the air-gapped machine."
