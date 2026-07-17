# P6.2 — Bundled sentence-embedder swap (BGE-small-en-v1.5)

The app ships with the machinery to run an on-device Core ML sentence embedder
in place of Apple's `NLEmbedding` (word-averaging, ~300-dim, slow cold start).
It is **inert until you supply the model asset** — with no model bundled,
`CoreMLEmbedderProvider.isAvailable()` is `false` and embedding falls back to
`NLEmbedding` exactly as before. Drop the model in and it activates on next launch.

## What's already wired (no further code needed)
- `Routing/Providers/CoreMLEmbedderProvider.swift` — a `.embedding` provider that
  loads the bundled model, tokenizes (via `BGETokenizer`), mean-pools over the
  attention mask (or takes a pre-pooled output), L2-normalizes, and returns 384-dim
  vectors. Returns `[]` when unavailable so the caller falls back.
- Registered in `AppState` over the `NLEmbedding` fallback via the capability layer.
- **Re-embedding reconciliation** (`AppState`, boot): when the model is present,
  any stored vectors at a different dimension are deleted and the HNSW cache is
  dropped, so the background drain re-embeds every chunk at 384-dim and the index
  rebuilds. Vectors are derived data — chunks/FTS/entities are untouched.

## Quickest path (one command)

```bash
scripts/build-bge-embedder.sh
```
Creates a venv, downloads BGE-small-en-v1.5, converts it to Core ML, and drops
`BGESmallEmbedder.mlpackage` + `vocab.txt` into `Kalsmritikosh/Resources/BGESmallEmbedder/`
(gitignored — regenerated per machine, like the reranker). Then rebuild in Xcode
and relaunch. The manual steps below are the same thing, spelled out.

## What you must supply

Two files in `Kalsmritikosh/Resources/BGESmallEmbedder/`, added to the app
target's **Copy Bundle Resources** phase (do this with Xcode — it's a pbxproj edit):

1. `BGESmallEmbedder.mlpackage` (or a compiled `BGESmallEmbedder.mlmodelc`)
2. `vocab.txt` (the model's BERT WordPiece vocabulary — one token per line, id =
   line index; the standard file `save_pretrained` emits alongside the model)

### Conversion (run once, Python venv with coremltools ≥ 8, transformers, torch)

```python
from huggingface_hub import snapshot_download
from transformers import AutoTokenizer, AutoModel
import torch, coremltools as ct

SRC = snapshot_download("BAAI/bge-small-en-v1.5")
tok = AutoTokenizer.from_pretrained(SRC)
tok.save_pretrained("out")          # -> out/vocab.txt (bundle this one)

mdl = AutoModel.from_pretrained(SRC, torchscript=True).eval()

class Pooled(torch.nn.Module):
    """Mean-pool over the attention mask + L2-normalize, so the Core ML
    output is a ready-to-use 384-dim sentence vector."""
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, input_ids, attention_mask):
        out = self.m(input_ids=input_ids, attention_mask=attention_mask)[0]  # [1, seq, 384]
        mask = attention_mask.unsqueeze(-1).float()
        summed = (out * mask).sum(1)
        counts = mask.sum(1).clamp(min=1e-9)
        v = summed / counts
        return torch.nn.functional.normalize(v, p=2, dim=1)                  # [1, 384]

wrapped = Pooled(mdl).eval()
ex = tok(["probe passage"], return_tensors="pt", padding="max_length",
         truncation=True, max_length=512)
traced = torch.jit.trace(wrapped, (ex["input_ids"], ex["attention_mask"]))
ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids",      shape=(1, 512), dtype=int),
        ct.TensorType(name="attention_mask", shape=(1, 512), dtype=int),
    ],
    minimum_deployment_target=ct.target.macOS14,
).save("BGESmallEmbedder.mlpackage")
```

The wrapper makes the model emit a pooled `[1, 384]` vector; the Swift side then
just L2-normalizes again (idempotent). If you export the raw `[1, seq, 384]`
output instead, the Swift provider mean-pools it — both work.

### Tokenizer
The embedder uses `BERTWordPieceTokenizer` (a dependency-free, uncased BERT
WordPiece tokenizer that reads `vocab.txt`) — the correct family for
`bge-small-en-v1.5`. It's unit-tested against the reference (`unaffable → un
##aff ##able`, punctuation splitting, lowercasing, accent stripping). Just make
sure the `vocab.txt` you bundle is the one that shipped with the model you
converted (the `save_pretrained` step above writes it to `out/vocab.txt`).

## Verify after bundling
1. Launch; check the log for `Embedder swap: cleared N stale-dimension vectors; re-embedding at dim 384`.
2. Settings → the "chunks missing vector" count should climb (re-embed queued) then drain to 0.
3. Semantic search returns results (query + stored vectors now both 384-dim).
4. Run the in-app SmokeTest against the ProjectDelta fixture — must stay green.
5. If `dimension` on the provider ≠ your model's real output size, set it in the
   `CoreMLEmbedderProvider()` init in `AppState` (the reconciliation keys off it).
