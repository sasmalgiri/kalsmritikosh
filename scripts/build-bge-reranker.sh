#!/usr/bin/env bash
# G2-RERANK-LADDER Tier 3 — one-time build of the bundled bge-reranker
# Core ML model. Run this once per machine; ~10 min, ~600 MB disk.
#
# Output lands in Kalsmritikosh/Resources/BGEReranker/ where Xcode's
# PBXFileSystemSynchronizedRootGroup picks it up automatically at the
# next build. The directory is .gitignored so the 531 MB weight blob
# never enters git history.
#
# Requires: Python 3.9+, ~3 GB RAM during conversion, internet for
# the Hugging Face download.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$HOME/coreml-bge"
RES_DIR="$PROJ_ROOT/Kalsmritikosh/Resources/BGEReranker"

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
pip install --quiet -U huggingface_hub coremltools transformers torch

echo "==> Running conversion (downloads model, traces, converts) ..."
python3 "$PROJ_ROOT/scripts/build-bge-reranker.py"

echo "==> Copying artefacts to $RES_DIR"
cp -R "$BUILD_DIR/BGEReranker.mlpackage"     "$RES_DIR/"
cp    "$BUILD_DIR/tokenizer.json"            "$RES_DIR/"
cp    "$BUILD_DIR/tokenizer_config.json"     "$RES_DIR/"
cp    "$BUILD_DIR/sentencepiece.bpe.model"   "$RES_DIR/" 2>/dev/null || true
cp    "$BUILD_DIR/special_tokens_map.json"   "$RES_DIR/"

echo "==> Done. Rebuild the Xcode project to bundle the new model."
echo "    G2-RERANK-LADDER Tier 3 will activate at runtime when"
echo "    KALSMRITIKOSH_RERANKER=ladder is set."
