# Drop the BGE embedder here

Put these two files in THIS folder, then add them to the app target's
**Copy Bundle Resources** phase in Xcode:

1. `BGESmallEmbedder.mlpackage`   (or a compiled `BGESmallEmbedder.mlmodelc`)
2. `vocab.txt`

Produce them with the conversion script in `docs/EMBEDDER_SWAP.md`.

Once both are present and bundled, the app auto-detects the model on next
launch, re-embeds every chunk at 384-dim, and rebuilds the vector index. Until
then the app embeds with Apple NLEmbedding (300-dim) — unchanged.
