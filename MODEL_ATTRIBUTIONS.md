# Model Attributions — Kalsmritikosh

Kalsmritikosh runs entirely on-device. It bundles / can download the following
machine-learning models. This file is the source of truth for the in-app
"About → Model licences" screen and the App Store attribution text.

## Reasoning models (Meta Llama)

**Built with Llama.**

- **Default (bundled):** Llama 3.2 3B Instruct — quantized to GGUF (Q4_K_M).
- **Optional (user download, 16 GB+ devices):** Llama 3.1 8B Instruct — GGUF.

Llama 3.x models are licensed under the **Llama 3.2 / Llama 3.1 Community License
Agreement** (© Meta Platforms, Inc.). Obligations Kalsmritikosh complies with:

1. **Attribution:** the app displays "Built with Llama" in About / onboarding,
   and this notice ships with the binary.
2. **Naming:** any model-facing name derived from these weights includes "Llama".
3. **Copy of the licence + Acceptable Use Policy** ships in the app bundle and in
   this repository (see `THIRD_PARTY_NOTICES.md`).
4. **Acceptable Use Policy:** the app does not use the model for any use Meta's AUP
   prohibits; the closed-corpus, evidence-grounded design constrains output to the
   user's own documents.
5. The 700M-MAU redistribution-threshold clause does not apply at this scale.

Licence texts:
- Llama 3.2: https://github.com/meta-llama/llama-models/blob/main/models/llama3_2/LICENSE
- Llama 3.1: https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/LICENSE
- Acceptable Use Policy: https://www.llama.com/llama3_2/use-policy

## Embedding model (BGE)

- **BAAI/bge-small-en-v1.5** — sentence embeddings (384-dim), converted to Core ML.
- Licence: **MIT** (© Beijing Academy of Artificial Intelligence). Permits bundling
  and redistribution with the licence text (included in `THIRD_PARTY_NOTICES.md`).

## Reranker (BGE cross-encoder)

- BGE reranker (Core ML) already bundled under `Resources/BGEReranker/`.
- Licence: MIT (BAAI). Included in `THIRD_PARTY_NOTICES.md`.

## Apple Foundation Models

- On Apple-Intelligence-capable Macs the app may also use Apple's on-device
  `FoundationModels`. Provided by the OS under Apple's SLA; no redistribution by
  Kalsmritikosh. No attribution obligation beyond Apple's terms.

---
Last updated: 2026-07-13. Refresh the licence URLs + exact model revisions at the
moment of App Store submission (model cards and licence versions can change).
