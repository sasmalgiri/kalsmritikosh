# CLAIMS.md — every public claim, mapped to the mechanism that proves it

PHASE E (seventh audit), rebuilt on explicit IDs (tenth audit). Rule: **an
enforcement, verifiability or privacy sentence may not ship on the website
unless its element carries a `data-claim="<id>"` attribute and that id has
exactly one row here with a living proof.** CI (`scripts/check-claims.sh`)
verifies on every push, in BOTH directions:

- registry → site: every row's id appears in a `data-claim` attribute, its
  verbatim fragment occurs INSIDE the text of at least one element carrying
  that id (structural — swapping ids between elements fails, eleventh
  audit), and its proof is alive;
- site → registry: every `data-claim` id found in the HTML has exactly one
  row here. An id may tag several elements (mirrors/paraphrases); the
  fragment must live inside at least one of them.

Coverage of untagged copy (twelfth audit): PRIVACY assertions found in text
OUTSIDE any `data-claim` element — including `<meta name="description">`
content — are FAILURES, not warnings (a meta tag carries `data-claim` like
any element). Enforcement-flavored copy remains a SECONDARY WARNING (the id
gate is the authority, per the tenth audit). CI self-tests the gate by
injecting an untagged privacy sentence and requiring failure.

Structural coverage (thirteenth audit): untagged text is AGGREGATED across
inline markup before matching, so `Nothing <em>is</em> uploaded` cannot split
a protected phrase past the regex. And privacy pages (`*privacy*.html`) are
claim ZONES: EVERY text node must live inside a `data-claim` or
`data-claims-exempt` element — uncovered text fails outright, so the gate does
not depend on the regex anticipating a new phrasing there. CI self-tests both
(the inline-split probe and an uncovered privacy-page sentence must fail).

Proof kinds:
- `test:<symbol>` — a named test in KalsmritikoshTests proves the behavior.
- `ci:<fragment>` — a CI step in .github/workflows enforces it on every push.
- `grep:<pattern>:<path>` — a structural property checked directly in source.
- `owner:<file>` — true only after a recorded owner act; the claim page must
  carry the conditional wording until that act is done.

| Claim ID | Verbatim fragment on the site | Proof |
|---|---|---|
| `workflow.element-gates` | `refuse to confirm without their required elements` | test:repositoryAssertionEnforcement |
| `conformance.approval-gate` | `approval is blocked until every rule of the frozen SOP` | test:failClosed |
| `conformance.fail-closed` | `unevaluated rules block conformance` | test:failClosed |
| `conformance.frozen-hash` | `frozen by hash` | test:snapshotHash |
| `conformance.strict-mode` | `strict conformance mode` | test:flagDefaultsOff |
| `conformance.classic-disclosure` | `disabling that enforcement` | grep:disables enforcement:Kalsmritikosh/UI/SettingsView.swift |
| `conformance.standards-enforced` | `Real standards, enforced` | test:failClosed |
| `conformance.refused-conclusions` | `conclusions the app refuses to assert` | test:repositoryAssertionEnforcement |
| `conformance.observed-phases` | `machine-observed phases` | test:certificateSplit |
| `verify.true-replay` | `reruns every evaluator` | ci:generate-kalverify |
| `verify.generated-cli` | `What you rerun is what the app ran` | ci:git diff --exit-code verifier/kalverify.swift |
| `verify.integrity` | `Every file matches the manifest` | test:tamperedFileFailsIntegrity |
| `verify.authenticity` | `recomputing hashes still fails` | test:recomputedForgeryFailsSignature |
| `verify.run-binding` | `run binding is recomputed` | test:runBindingRecomputes |
| `verify.signed-facts` | `the facts hash is signed` | test:factsReplayCatchesWrongEvaluations |
| `trail.public-replay` | `replays a keyless` | test:publicChainSealsAndReplays |
| `trail.metadata-bound` | `trail metadata cannot be edited` | test:publicChainSealsAndReplays |
| `studios.hardcopy` | `end in the actual hardcopy` | test:hardcopy |
| `studios.deliverable-seal` | `deliverable seal` | test:studioSealVerifies |
| `studios.unsealed-disclosure` | `UNSEALED` | grep:_UNSEALED:Kalsmritikosh/Core/Security/ConformanceSeal.swift |
| `receipts.sealed` | `sealed receipt` | ci:report-receipt-integrity |
| `answers.traceable` | `every line traceable to a source` | test:ungroundedFlagged |
| `answers.refuses-to-guess` | `refuses to guess` | test:missingEvidenceIncomplete |
| `answers.evidence-gate` | `enforced evidence gate` | test:missingEvidenceIncomplete |
| `answers.refuses-unsupported` | `refuses when the record` | test:missingEvidenceIncomplete |
| `journalism.reply-gate` | `right of reply enforced` | test:stages |
| `privacy.no-egress` | `no network connections` | ci:sensitive-export |
| `privacy.on-device` | `100% on-device` | ci:sensitive-export |
| `privacy.never-leaves` | `never leave your Mac` | ci:sensitive-export |
| `privacy.no-servers` | `No servers. No accounts. No analytics` | ci:sensitive-export |
| `privacy.models-bundled` | `models ship inside the app` | owner:OWNER_ACCEPTANCE_CHECKLIST.md |
| `privacy.erase-everything` | `One click erases the entire ledger` | grep:FULL ERASE:Kalsmritikosh/App/AppState.swift |
| `privacy.private-by-design` | `Erase everything in one click` | grep:FULL ERASE:Kalsmritikosh/App/AppState.swift |
| `privacy.nothing-collected` | `Data Not Collected` | owner:OWNER_ACCEPTANCE_CHECKLIST.md |
| `privacy.no-upload` | `Nothing is uploaded, ever` | ci:sensitive-export |
| `privacy.offline` | `Works fully offline` | ci:sensitive-export |
| `privacy.no-copy` | `not copied to us` | ci:sensitive-export |
| `privacy.local-only` | `stored only in the app's local database` | ci:sensitive-export |
| `privacy.no-cloud-model` | `never sent to a cloud model` | ci:sensitive-export |
| `privacy.no-cloud` | `no cloud` | ci:sensitive-export |
| `privacy.exports-local` | `never uploaded` | ci:sensitive-export |
| `privacy.diagnostics-manual` | `never sent automatically` | ci:sensitive-export |

Coverage boundary (eighth–tenth audits, stated honestly): the registry
registers the site's ENFORCEMENT, VERIFIABILITY and PRIVACY claims — the
sentences whose falsehood would mislead a verifier or a buyer about what the
software enforces. The `data-claim` id gate is the mechanical authority in
both directions; the keyword scan is a secondary warning that flags likely
enforcement copy shipped untagged. Purely narrative copy that asserts
nothing enforceable is out of scope by design; the rule for humans remains
that any sentence asserting an enforcement or guarantee MUST get a tagged
element and a row before it ships.

Claims that must NEVER appear (refused vocabulary — CI fails if found):
- "provable compliance" / "provably compliant"
- "legally compliant" / "guarantees compliance"
- "court-admissible" (admissibility is a court's decision, never a vendor's)
