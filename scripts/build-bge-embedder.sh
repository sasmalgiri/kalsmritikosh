#!/usr/bin/env bash
# P6.2 — one-time build of the bundled BGE-small-en-v1.5 sentence embedder
# Core ML model + vocab. Run this once per machine; ~5 min, ~600 MB disk.
#
# Output lands in Kalsmritikosh/Resources/BGESmallEmbedder/ where Xcode's
# PBXFileSystemSynchronizedRootGroup picks it up automatically at the next
# build. The directory is .gitignored so the weight blob never enters git
# history (mirrors build-bge-reranker.sh).
#
# Requires: Python 3.9+, ~3 GB RAM during conversion, internet for the
# Hugging Face download.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$HOME/coreml-bge-embedder"
RES_DIR="$PROJ_ROOT/Kalsmritikosh/Resources/BGESmallEmbedder"

echo "==> Build dir:      $BUILD_DIR"
echo "==> Destination:    $RES_DIR"

mkdir -p "$BUILD_DIR" "$RES_DIR"
cd "$BUILD_DIR"

if [[ ! -d ".venv" ]]; then
    echo "==> Creating venv"
    python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -U "numpy<2" huggingface_hub coremltools transformers torch

echo "==> Running conversion (downloads model, traces, converts) ..."
python3 "$PROJ_ROOT/scripts/build-bge-embedder.py" "$RES_DIR"

echo "==> Done. Rebuild the Xcode project to bundle the new model."
echo "    On next app launch the embedder switches to BGE (384-dim) and the"
echo "    background drain re-embeds every chunk; the vector index rebuilds."
