# RELEASE_EVIDENCE_v1

_Release-evidence record (REL-006 / spec §9). Prefilled with what is known headlessly; the
bracketed `[owner: …]` fields require an owner-run build / app run / hardware and must be filled
before submission. No submission until `18_DEFINITION_OF_DONE_AND_RELEASE_GATES.md` has no
unresolved blocker (§10)._

## Build identity

| Field | Value |
|---|---|
| git SHA | `3e8d57e` _(update to the tagged release commit)_ |
| Schema version | **v59** (`SchemaMigrations.latestVersion`) |
| App version / build | `[owner: e.g. 1.0 (1)]` |
| Xcode / macOS SDK | `[owner: e.g. Xcode 26.x / macOS 26 SDK]` |
| Minimum OS | macOS 26 (`MACOSX_DEPLOYMENT_TARGET = 26.0`) — `[owner: confirm set in pbxproj]` |
| Test hardware | `[owner: model, chip, RAM]` |
| Reasoning model | Apple Foundation Models (on-device) where available; deterministic engine otherwise. No bundled/third-party LLM in release. |
| Embedding model | Bundled BGE-small-en-v1.5, 384-dim Core ML |

## Test results

| Suite | Result |
|---|---|
| Unit + integration (`KalsmritikoshTests`) | **443 passing, 0 failing** (headless, this SHA) |
| Migration (throwaway-DB, up to v59) | Passing (covered by repo/migration tests) |
| Parser format matrix (PAR-010 guard) | Passing (advertised = parseable) |
| Redaction verification (RED-002) | Passing |
| Security fixtures (SEC-003) | `[owner: run under the test target in CI]` |
| Gold retrieval eval (EVAL-001, 60Q) | `[owner: run in-app; record recall/citation metrics]` |

## Gold metrics

`[owner: paste EVAL-001 baseline — recall@k, citation-accuracy, refusal-correctness — from an in-app eval run]`

## Large-corpus metrics (SCL-001…004)

`[owner: record ingest time + query latency + peak memory at 1 GB / 10 GB / <advertised> GB on the test hardware; the store "tested to N GB" figure comes from this]`

## Privacy / security results

- Release build contains **no network provider** (`PrivacyGate` filters cloud; `#if DEBUG` gates dev providers). `[owner: run a network-egress audit on the release binary to confirm zero egress]`
- `PrivacyInfo.xcprivacy` present + "Data Not Collected". `[owner: confirm bundled]`
- Sensitive-logging audit: no raw evidence at default log level. `[owner: confirm]`

## Clean-machine result (REL-002)

`[owner: install the signed release on a clean minimum-spec Mac; confirm full journey — add folder → ingest → ask → cited answer → export — with no dev tools present]`

## Known limitations (v1)

- Audio/video recognized but not transcribed (deferred by design).
- Some legacy/office formats extracted with disclosed limits; a few preserved-only.
- Optional downloaded local GGUF models deferred to v1.x (GOV-001).
- Advertised scale is the recorded tested figure only.
- New UI components (Table Workbench / Evidence Canvas / chart / report editor) are compile-verified;
  confirm rendering in the clean-machine run.

## Owner sign-off

- [ ] `[owner]` I have run the app on target hardware and completed the full journey.
- [ ] `[owner]` Gold + large-corpus metrics recorded above.
- [ ] `[owner]` Privacy egress audit clean; `PrivacyInfo.xcprivacy` present.
- [ ] `[owner]` Store copy matches this binary (no over-claims).
- [ ] `[owner]` No unresolved blocker in `18_DEFINITION_OF_DONE_AND_RELEASE_GATES.md`.
- [ ] `[owner]` Signed archive builds and validates in App Store Connect.

Signed: `[owner name / date]`
