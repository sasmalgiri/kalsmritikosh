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

print("=== Stage 1: snapshot_download ===", flush=True)
from huggingface_hub import snapshot_download

src = snapshot_download("BAAI/bge-reranker-base")
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
print(f"DONE → {out_path}", flush=True)
print(f"Files in {out_dir}:", flush=True)
for f in sorted(os.listdir(out_dir)):
    full = os.path.join(out_dir, f)
    size = os.path.getsize(full) if os.path.isfile(full) else "<dir>"
    print(f"  {size}  {f}", flush=True)
