# Third-Party Notices — Kalsmritikosh

**v1 ships exactly two third-party model families: the bundled BGE embedder and
BGE reranker (both MIT).** The shipping notice text lives at
`Kalsmritikosh/Resources/THIRD_PARTY_NOTICES.txt` and is packaged inside the app
bundle (the folder is a synchronized target group). No Llama model, no llama.cpp
runtime, and no other third-party weights ship in v1 — the reasoning provider is
Apple Foundation Models (part of macOS 26+), runtime-gated, with the deterministic
engine everywhere (SHIP_DECISIONS §1, GOV-001/GOV-004).

---

## BGE models (FlagEmbedding project, BAAI) — MIT License

- `BAAI/bge-small-en-v1.5` (embedder) — pinned revision `5c38ec7c405ec4b44b94cc5a9bb96e735b38267a`
- `BAAI/bge-reranker-base` (reranker) — pinned revision `2cfc18c9415c912f9d8155881c133215df768a70`

Both Hugging Face repos declare MIT via metadata (no LICENSE file in the model
repo); the verbatim upstream licence is the FlagEmbedding project's MIT text.
The build scripts download ONLY these pinned revisions and write a
`MODEL_PIN.json` (source revision + sha256 of every produced artifact) next to
each compiled model, so the archive's models are provably the pinned builds.

MIT License

Copyright (c) 2022 staoxiao

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be included in all copies
or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## Apple frameworks

FoundationModels, Core ML, Vision, PDFKit, NaturalLanguage, etc. are provided under the
Apple SDK Agreement; no separate redistribution notice required.

---

## v1.x OPTIONAL — NOT SHIPPED IN v1 (do not attach to a v1 submission)

Retained for the deferred optional downloaded-GGUF path only (SHIP_DECISIONS §4).
If that path ever ships, paste the verbatim licence bodies before submission:

- **Meta Llama 3.2 / 3.1** — © Meta Platforms, Inc., Llama Community License
  Agreement; "Built with Llama" attribution and naming obligations per
  `MODEL_ATTRIBUTIONS.md`.
- **llama.cpp** — © 2023 The ggml authors / Georgi Gerganov, MIT; pin the exact
  commit/tag when the dependency lands (P1.2).

---
Last updated: 2026-08-27 (release-readiness pass: Llama/llama.cpp moved to the
non-shipping v1.x section; the shipping BGE notice is bundled as a target resource).
