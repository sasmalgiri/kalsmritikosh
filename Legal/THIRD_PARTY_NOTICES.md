> **SUPERSEDED 2026-10-28 (review L6).** This draft still lists Meta Llama (not shipped) and omits SQLCipher. The notices
> that ship are `Kalsmritikosh/Resources/THIRD_PARTY_NOTICES.txt` (BGE models MIT, SQLCipher 4.19.0 BSD, SQLite public
> domain); the repository copy is `THIRD_PARTY_NOTICES.md` at the root.

# Third-Party Notices — Kalsmritikosh

> **DRAFT — verify each license obligation before publication.** Bundle the full
> license texts referenced below with the app (e.g., in Settings → Legal, or an
> Acknowledgements file shipped in the app bundle).

## Meta Llama (on-device reasoning)
- Component: Meta Llama 3.x models (on-device).
- License: **Llama Community License Agreement** (Meta).
- **Required attribution (already shown in-app):** "Built with Llama."
- Obligations to confirm and satisfy:
  - Include a copy of the **Llama Community License** and the **Acceptable Use
    Policy** with the distribution. → Add `Legal/LICENSES/LLAMA_COMMUNITY_LICENSE.txt`.
  - Display "Built with Llama" (done — see `LegalNotice.modelAttribution`).
  - If any product/model name is derived from Llama, include "Llama" per the
    naming requirement.
  - The >700M monthly-active-users clause does not apply to typical indie
    distribution; confirm your scale.

## BGE embedding + reranker models (on-device semantic search)
- License: **MIT.**
- Obligation: include the MIT license text + copyright notice. →
  `Legal/LICENSES/BGE_MIT_LICENSE.txt`.

## Apple frameworks
- Vision, Speech, Natural Language, Core ML, PDFKit, ImageIO, SwiftUI, Charts,
  CryptoKit — used under the Apple SDK/Developer Program terms. No separate
  redistribution notice required beyond Apple's terms.

## Action items
- [x] `Legal/LICENSES/BGE_MIT_LICENSE.txt` added (verify the exact BGE variant).
- [~] `Legal/LICENSES/LLAMA_LICENSE_README.md` added — pointer + obligations checklist.
- [ ] Add `Legal/LICENSES/LLAMA_COMMUNITY_LICENSE.txt` (official text for your
      bundled version — URLs in the README). **Owner action.**
- [ ] Add `Legal/LICENSES/LLAMA_ACCEPTABLE_USE_POLICY.txt`. **Owner action.**
- [ ] Confirm the in-app Acknowledgements screen lists all of the above.
