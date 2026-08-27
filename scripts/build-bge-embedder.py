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

def write_model_pin(dest, repo, revision, artifacts):
    """Record the pinned source + sha256 of every produced artifact file, so the
    final archive's models are provably the ones built from the pinned revision."""
    manifest = {"repo": repo, "revision": revision,
                "license": "MIT (FlagEmbedding project, Copyright (c) 2022 staoxiao)",
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
    out = os.path.join(dest, "MODEL_PIN.json")
    with open(out, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    print(f"==> wrote {out} ({len(manifest['artifacts'])} artifact hashes)", flush=True)
from huggingface_hub import snapshot_download
from transformers import AutoTokenizer, AutoModel
import coremltools as ct

DEST = sys.argv[1] if len(sys.argv) > 1 else "Kalsmritikosh/Resources/BGESmallEmbedder"
os.makedirs(DEST, exist_ok=True)

EMBEDDER_REPO = "BAAI/bge-small-en-v1.5"
EMBEDDER_REVISION = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
print(f"==> downloading {EMBEDDER_REPO} @ {EMBEDDER_REVISION} (pinned) ...", flush=True)
SRC = snapshot_download(EMBEDDER_REPO, revision=EMBEDDER_REVISION)
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
write_model_pin(DEST, EMBEDDER_REPO, EMBEDDER_REVISION, ["BGESmallEmbedder.mlpackage", "vocab.txt"])
print(f"==> OK — saved BGESmallEmbedder.mlpackage + vocab.txt to {DEST} (output {shape})", flush=True)
