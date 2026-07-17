#!/usr/bin/env python3
# P6.2 — one-time build of the bundled BGE-small-en-v1.5 sentence embedder as a
# Core ML model, plus its BERT WordPiece vocab. Mirrors build-bge-reranker.py.
#
# Output lands in Kalsmritikosh/Resources/BGESmallEmbedder/ where Xcode's
# PBXFileSystemSynchronizedRootGroup picks it up at the next build. That
# directory is .gitignored so the weight blob never enters git history.
#
# Emits:
#   BGESmallEmbedder.mlpackage   — mean-pooled + L2-normalized [1,384] sentence vector
#   vocab.txt                    — the model's BERT WordPiece vocabulary
#
# Usage: python build-bge-embedder.py <dest_dir>
import os, sys, shutil, numpy as np, torch
from huggingface_hub import snapshot_download
from transformers import AutoTokenizer, AutoModel
import coremltools as ct

DEST = sys.argv[1] if len(sys.argv) > 1 else "Kalsmritikosh/Resources/BGESmallEmbedder"
os.makedirs(DEST, exist_ok=True)

print("==> downloading BAAI/bge-small-en-v1.5 ...", flush=True)
SRC = snapshot_download("BAAI/bge-small-en-v1.5")
tok = AutoTokenizer.from_pretrained(SRC)
tmp = os.path.join(DEST, "_tok_tmp")
tok.save_pretrained(tmp)                       # writes vocab.txt

mdl = AutoModel.from_pretrained(SRC, torchscript=True).eval()

class Pooled(torch.nn.Module):
    """Mean-pool the token embeddings over the attention mask + L2-normalize,
    so the Core ML output is a ready-to-use 384-dim sentence vector."""
    def __init__(self, m):
        super().__init__(); self.m = m
    def forward(self, input_ids, attention_mask):
        out = self.m(input_ids=input_ids, attention_mask=attention_mask)[0]
        mask = attention_mask.unsqueeze(-1).float()
        v = (out * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        return torch.nn.functional.normalize(v, p=2, dim=1)

w = Pooled(mdl).eval()
ex = tok(["probe passage"], return_tensors="pt", padding="max_length",
         truncation=True, max_length=512)
print("==> tracing ...", flush=True)
traced = torch.jit.trace(w, (ex["input_ids"], ex["attention_mask"]))

print("==> converting to Core ML ...", flush=True)
mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, 512), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, 512), dtype=np.int32),
    ],
    minimum_deployment_target=ct.target.macOS14,
)
mlmodel.save(os.path.join(DEST, "BGESmallEmbedder.mlpackage"))
shutil.copy(os.path.join(tmp, "vocab.txt"), os.path.join(DEST, "vocab.txt"))
shutil.rmtree(tmp, ignore_errors=True)

# Sanity: the Swift side expects a [1,384] output.
pred = mlmodel.predict({"input_ids": ex["input_ids"].int().numpy(),
                        "attention_mask": ex["attention_mask"].int().numpy()})
shape = np.array(list(pred.values())[0]).shape
assert shape == (1, 384), f"unexpected output shape {shape}"
print(f"==> OK — saved BGESmallEmbedder.mlpackage + vocab.txt to {DEST} (output {shape})", flush=True)
