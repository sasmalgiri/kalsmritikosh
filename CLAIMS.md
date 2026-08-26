# CLAIMS.md — every public claim, mapped to the mechanism that proves it

PHASE E (seventh audit). Rule: **a sentence may not ship on the website
unless it appears here with a living proof.** CI (`scripts/check-claims.sh`)
verifies on every push that (a) each registered claim still appears on the
live site source, and (b) each named proof still exists — a claim whose copy
drifted or whose test was deleted fails the build. Adding new marketing copy
means adding a row here first.

Proof kinds:
- `test:<symbol>` — a named test in KalsmritikoshTests proves the behavior.
- `ci:<fragment>` — a CI step in .github/workflows enforces it on every push.
- `grep:<pattern>:<path>` — a structural property checked directly in source.
- `owner:<file>` — true only after a recorded owner act; the claim page must
  carry the conditional wording until that act is done.

| Claim (verbatim fragment on the site) | Proof |
|---|---|
| `refuse to confirm without their required elements` | test:repositoryAssertionEnforcement |
| `approval is blocked until every rule of the frozen SOP` | test:failClosed |
| `unevaluated rules block conformance` | test:failClosed |
| `frozen by hash` | test:snapshotHash |
| `strict conformance mode` | test:flagDefaultsOff |
| `reruns every evaluator` | ci:generate-kalverify |
| `What you rerun is what the app ran` | ci:git diff --exit-code verifier/kalverify.swift |
| `Every file matches the manifest` | test:tamperedFileFailsIntegrity |
| `recomputing hashes still fails` | test:recomputedForgeryFailsSignature |
| `run binding is recomputed` | test:runBindingRecomputes |
| `the facts hash is signed` | test:factsReplayCatchesWrongEvaluations |
| `no network connections` | ci:sensitive-export |
| `100% on-device` | ci:sensitive-export |
| `models ship inside the app` | owner:OWNER_ACCEPTANCE_CHECKLIST.md |
| `sealed receipt` | ci:report-receipt-integrity |
| `machine-observed phases` | test:certificateSplit |
| `every line traceable to a source` | test:ungroundedFlagged |
| `end in the actual hardcopy` | test:hardcopy |
| `deliverable seal` | test:studioSealVerifies |
| `UNSEALED` | grep:_UNSEALED:Kalsmritikosh/Core/Security/ConformanceSeal.swift |
| `replays a keyless` | test:publicChainSealsAndReplays |
| `trail metadata cannot be edited` | test:publicChainSealsAndReplays |
| `Real standards, enforced` | test:failClosed |
| `conclusions the app refuses to assert` | test:repositoryAssertionEnforcement |
| `refuses to guess` | test:missingEvidenceIncomplete |
| `enforced evidence gate` | test:missingEvidenceIncomplete |
| `refuses when the record` | test:missingEvidenceIncomplete |
| `disabling that enforcement` | grep:disables enforcement:Kalsmritikosh/UI/SettingsView.swift |
| `right of reply enforced` | test:stages |

Coverage boundary (eighth + ninth audits, stated honestly): the registry
registers the site's ENFORCEMENT, VERIFIABILITY and PRIVACY claims — the
sentences whose falsehood would mislead a verifier or a buyer about what the
software enforces. BOTH directions are now checked mechanically:
registry → site (every row's copy must still exist, its proof must be alive),
and site → registry (any line matching the enforcement-keyword heuristic in
`scripts/check-claims.sh` must carry a registered fragment or an explicit
`claims-exempt` marker for disclaimers). The keyword heuristic is exactly
that — a heuristic: purely narrative copy that asserts nothing enforceable
is out of scope by design, and a claim phrased without any trigger keyword
would evade the gate; the rule for humans remains that any sentence
asserting an enforcement or guarantee MUST get a row before it ships.

Claims that must NEVER appear (refused vocabulary — CI fails if found):
- "provable compliance" / "provably compliant"
- "legally compliant" / "guarantees compliance"
- "court-admissible" (admissibility is a court's decision, never a vendor's)
