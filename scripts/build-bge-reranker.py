#!/usr/bin/env python3
"""
G2-RERANK-LADDER Tier 3 — convert BAAI/bge-reranker-base to Core ML
and copy the tokenizer assets next to the .mlpackage so the Swift
wrapper can bundle both into Resources/.
"""

import os
import shutil
import sys
import warnings

warnings.filterwarnings("ignore")


# RELEASE PIN (fifteenth review) — a mutable Hugging Face HEAD download can
# never be release evidence. The revision below is the exact repo commit this
# release converts; refresh deliberately (and re-record) via
#   https://huggingface.co/api/models/<repo>  (field "sha").
# Both BGE repos are MIT (FlagEmbedding project, Copyright (c) 2022 staoxiao).
import hashlib, json

def _sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def _toolchain():
    """D-5 — record the converting toolchain so a hash mismatch can be
    attributed (a coremltools/torch bump changes compiled bytes)."""
    import platform, importlib
    versions = {"python": platform.python_version()}
    for mod in ("coremltools", "torch", "transformers", "huggingface_hub"):
        try:
            versions[mod] = importlib.import_module(mod).__version__
        except Exception:
            versions[mod] = "unknown"
    return versions

def write_model_pin(dest, repo, revision, artifacts, pin_name):
    """Record the pinned source + sha256 of every produced artifact file, so the
    final archive's models are provably the ones built from the pinned revision.
    pin_name must be UNIQUE across model dirs: Xcode's synchronized folder
    flattens loose files into Contents/Resources, so two files both named
    MODEL_PIN.json collide ("Multiple commands produce …")."""
    import platform
    manifest = {"repo": repo, "revision": revision,
                "license": "MIT (FlagEmbedding project, Copyright (c) 2022 staoxiao)",
                "toolchain": _toolchain(),
                "built_on": platform.platform(),
                "artifacts": {}}
    for a in artifacts:
        p = os.path.join(dest, a)
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for fn in sorted(files):
                    fp = os.path.join(root, fn)
                    manifest["artifacts"][os.path.relpath(fp, dest)] = _sha256(fp)
        elif os.path.isfile(p):
            manifest["artifacts"][a] = _sha256(p)
    out = os.path.join(dest, pin_name)
    with open(out, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    print(f"==> wrote {out} ({len(manifest['artifacts'])} artifact hashes)", flush=True)

print("=== Stage 1: snapshot_download ===", flush=True)
from huggingface_hub import snapshot_download

RERANKER_REPO = "BAAI/bge-reranker-base"
RERANKER_REVISION = "2cfc18c9415c912f9d8155881c133215df768a70"  # pinned — see build-bge-embedder.py note
src = snapshot_download(RERANKER_REPO, revision=RERANKER_REVISION)
print(f"  → snapshot at {src}", flush=True)

# Copy tokenizer assets up next to the .mlpackage.
out_dir = os.path.expanduser("~/coreml-bge")
for name in ["tokenizer.json", "tokenizer_config.json",
             "sentencepiece.bpe.model", "special_tokens_map.json"]:
    p = os.path.join(src, name)
    if os.path.exists(p):
        shutil.copy(p, os.path.join(out_dir, name))
        print(f"  copied {name}", flush=True)

print("=== Stage 2: load model ===", flush=True)
from transformers import AutoTokenizer, AutoModelForSequenceClassification

tok = AutoTokenizer.from_pretrained(src)
mdl = AutoModelForSequenceClassification.from_pretrained(
    src, torchscript=True
).eval()

print("=== Stage 3: trace ===", flush=True)
import torch

example = tok(
    ["query"], ["passage"],
    return_tensors="pt",
    padding="max_length",
    truncation=True,
    max_length=512,
)
traced = torch.jit.trace(
    mdl,
    (example["input_ids"], example["attention_mask"]),
)

print("=== Stage 4: coremltools convert ===", flush=True)
import coremltools as ct

mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, 512), dtype=int),
        ct.TensorType(name="attention_mask", shape=(1, 512), dtype=int),
    ],
    minimum_deployment_target=ct.target.macOS14,
)

print("=== Stage 5: save .mlpackage ===", flush=True)
out_path = os.path.join(out_dir, "BGEReranker.mlpackage")
mlmodel.save(out_path)
artifacts = ["BGEReranker.mlpackage", "tokenizer.json", "tokenizer_config.json",
             "special_tokens_map.json", "sentencepiece.bpe.model"]
write_model_pin(out_dir, RERANKER_REPO, RERANKER_REVISION,
                [a for a in artifacts if os.path.exists(os.path.join(out_dir, a))],
                pin_name="BGEReranker.MODEL_PIN.json")
print(f"DONE → {out_path}", flush=True)
print(f"Files in {out_dir}:", flush=True)
for f in sorted(os.listdir(out_dir)):
    full = os.path.join(out_dir, f)
    size = os.path.getsize(full) if os.path.isfile(full) else "<dir>"
    print(f"  {size}  {f}", flush=True)
