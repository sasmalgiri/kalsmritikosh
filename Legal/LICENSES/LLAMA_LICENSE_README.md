# Llama license — action required before ship

The on-device reasoning model is **Meta Llama** (per `LegalNotice`: Llama 3.2 /
3.1). It ships under the **Llama Community License Agreement**, which has
**version-specific text**. I have deliberately **not** pasted the license body
here, because it must match the exact model version you bundle and must be the
authentic Meta text (not paraphrased).

## Do this before submitting
1. Confirm the exact model version you ship (e.g. Llama 3.2 1B/3B, or Llama 3.1 8B).
2. Download the **official** license + acceptable-use policy for that version and
   save them next to this file as:
   - `LLAMA_COMMUNITY_LICENSE.txt`
   - `LLAMA_ACCEPTABLE_USE_POLICY.txt`
   Official sources:
   - https://www.llama.com/llama3_2/license/  (Llama 3.2)
   - https://www.llama.com/llama3_1/license/  (Llama 3.1)
   - https://www.llama.com/llama3_2/use-policy/  (Acceptable Use Policy)
3. Verify these obligations are met:
   - **Attribution:** display "Built with Llama" — already shown in-app
     (`LegalNotice.modelAttribution`). ✅
   - **Include the license text** with the distribution (the two files above).
   - **Naming:** if any product/model/feature name is derived from the model,
     include "Llama" at the start of that name.
   - **Acceptable Use Policy** — your product and its enabled uses must comply.
   - **>700M MAU clause** — does not apply at typical indie scale; confirm.
4. Ensure the in-app Acknowledgements screen lists Llama + links/points to these
   files, alongside `BGE_MIT_LICENSE.txt`.

This is the last third-party-license item on the ship checklist
(see `../THIRD_PARTY_NOTICES.md`).
