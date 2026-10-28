# Data-flow inventory — the one source for privacy statements

Version 1 · 2026-10-27 · derived from the code at `investigations-next` (after eea25503) · ship-readiness review L1.

Every privacy statement must agree with this file: the in-app privacy text (`LegalNotice.privacyStatement`), the
public pages (`docs/privacy.html`, `docs/terms.html`), `PrivacyInfo.xcprivacy`, `LEGAL_READINESS.md`,
`APP_STORE_RELEASE.md`, the listing and the App Store Connect answers. When a flow changes, update this file
first, bump its version and date, then update the rest. Superseded drafts stay marked as superseded.

This is an engineering inventory, not legal advice. **Choosing the App Store privacy label is an open
owner/counsel decision** (§4). Optional use does not by itself make disclosure optional.

## 1. Leaving the Mac (network)

Only one process can open a network connection: the **KalsmritikoshNetworkHelper** extension. It is embedded in
Debug and Release, has outgoing connections enabled, and accepts only HTTPS POST to three hosts:
`api.anthropic.com`, `api.openai.com` and `generativelanguage.googleapis.com`. It logs nothing and keeps no
cache or cookies. The main app has no network client entitlement.

| # | What | To | When | Default | Consent / limits | Recorded |
|---|---|---|---|---|---|---|
| N1 | The **question** and, for the interpreter, the app's field names and descriptions | The provider the person chose, with their own API key | Online mode, when the rules and the on-device model did not understand the question | Off. Needs Online mode and a key. The interpreter module is on, but sends only in Online mode. | Preview of the exact text, destination and size. "Ask every time" is the default. If the person turns it off, they may allow the rest of the session for question-only sends. Optional name masking is **off by default**. Daily byte limit. | `outbound_log` in the encrypted ledger: the full text sent (after masking), its SHA-256, size, provider, model, host and outcome. The response body is not stored. |
| N2 | **Document passages**, from two routes only. *Answer wording*: the answer synthesiser and the chunk fallback. *Record reading*: up to 8 documents naming a person, up to 7,000 characters each. Before any prompt is built, each source document passes the cloud source gate: privileged, above confidential, or protection unreadable/untraceable means it is not sent. Background, ingest, summary and expert calls cannot reach the cloud (they do not declare it). | Only a provider reviewed for case material (Claude on the commercial API, or a paid Gemini project; **not OpenAI** in this release), after the person confirms their account is on those terms. The confirmation lapses when the reviewed terms change. | Online mode with AI answers on; record reading has its own switch | Off | **Always previewed** with the provider's retention and training terms; never covered by "this session". Masking and the daily limit as in N1. | As N1. A refused send is logged as `blocked`, with the unsent text, inside the encrypted ledger. |
| N3 | Product lookup, entitlements, purchase, restore | Apple, through StoreKit | At launch (entitlements); on the person's action (purchase, restore) | On | Apple's own sheets | Nothing beyond StoreKit |
| N4 | "Report a problem": the app and macOS version | The person's Mail app, as a draft to the developer | Person's click | — | Editable draft; nothing is sent by the app | — |
| N5 | "Send diagnostics": MetricKit JSON (crash and hang stacks, counters, device model, OS) | The person's Mail app | Person's click, after a list of the files | — | The person sends it, or not | — |

What does **not** happen: no analytics, telemetry, advertising or tracking identifiers; no CloudKit or iCloud
key-value store; no model downloads in Release (the embedding and reranking models ship in the app); no update
check. The older local-model and cloud providers (Ollama, MLX, custom endpoints) exist only in DEBUG builds.

**Provider retention is the provider's.** The publisher receives nothing that is sent, but that does not mean the
provider keeps nothing:
- Anthropic's commercial API deletes inputs and outputs within 30 days by default, with stated exceptions.
- Google's unpaid Gemini tier may use content and have it reviewed by people.

The terms the app shows live in `OnlineProviderKind.documentTerms`, reviewed 2026-10-27.

## 2. Written outside the encrypted ledger (on this Mac or in a place the person chooses)

| # | What | Where | Protection | When |
|---|---|---|---|---|
| L1 | Copies of originals (managed vault) | `EvidenceVault/` beside the ledger, read-only | **Not encrypted** by the app (FileVault applies) | `managedEvidenceMode`, off by default |
| L2 | Vector index cache: quantised chunk embeddings and chunk ids | `hnsw-index.bin` beside the ledger | Not encrypted | Automatic |
| L3 | Captured / shared items and their custody log | `Intake/<date>/`, the App Group `Inbox/` until drained | Not encrypted | When capture is used (`captureExtensions` off by default; on in the "standalone" preset) |
| L4 | Import receipts: file names, hashes, errors, sometimes paths | `Receipts/` beside the ledger | Signed, not encrypted | `signedReceipts` |
| L5 | Exports: studio reports, case reports, proof bundles, CSVs | Where the person saves them | Not encrypted (they are the deliverable) | Person's action |
| L6 | Backups | Where the person chooses | Ledger encrypted with the ledger key. In a *complete* backup, **originals and the source map are not encrypted**. | Person's action |
| L7 | Companion snapshot | Where the person chooses | Ledger re-encrypted with an export passphrase. Originals, manifest file names and the source map are not encrypted. | Person's action |
| L8 | Folder sync: notes, tags, highlights, in-app files | The person's chosen folder (that folder's service moves it) | AES-GCM with a passphrase-derived key, signed. `store.json` and `devices/<id>.json` (device id and the **Mac's name**) are plaintext. | `folderSync`, off by default; on in the "standalone" preset |
| L9 | Team review (preview feature): case name, member name, document names, coding, notes | A shared folder | Signed and hash-chained, not encrypted | Hidden unless preview features are shown |
| L10 | Spotlight: file name and the first 240 characters of a document (up to 2,000) | The macOS index | System | `spotlightIndex`, off by default; on in the "standalone" preset. Turning it off removes the items. |
| L11 | Temporary files during import (unzipped office files, renders, email attachments, archive members) | `$TMPDIR` | Not encrypted | Automatic |
| L12 | DEVONthink hand-off: question, answer, citations as Markdown | `$TMPDIR/kalsmritikosh-devonthink/`, then DEVONthink | Not encrypted | Person's action (module on by default) |
| L13 | MetricKit diagnostics | `Diagnostics/*.json`, last 30 kept | Not encrypted | Automatic. Apple receives them only if the person shares analytics with developers in macOS. |
| L14 | Unified log: counts and errors; **file names and provider error texts are logged as public** | macOS log | System | Automatic |
| L15 | Preferences that hold content: self-score questions and expected answers, SOP drafts and reviews, job titles and result summaries per case, investigator name and organisation (default: the macOS full name), Online provider, model and terms confirmations | The app's preferences file | Not encrypted | As used. Studio drafts moved into the ledger (v158/v159); the old preference copy is cleared only after verification. |
| L16 | Keychain: ledger key, Online API keys, sync keys, seal, audit and team keys | Keychain, this device only | Keychain | — |
| L17 | Clipboard: answers and reports the person copies. The recovery key is copied for this Mac only and marked concealed and transient. | Pasteboard | — | Person's action |

## 3. Retraction, erasure and retention

Removing a studio draft **retracts** it: the draft is kept, with its revisions and export snapshots. That is not
erasure. "Removing the app's data folder" does not reach everything in the list:
- Keychain items
- Spotlight entries
- sync, backup, snapshot and export locations
- the shared-folder files

**Erasure of studio work (v160):** Erase, with a required reason and an optional basis, clears the draft's
content, every revision, every export snapshot and any quarantined legacy copy. The rows stay, with dates and
SHA-256s, and the erasure is recorded: who, when, why and on what basis. Erasure is refused while a legal hold
(`legal_holds`) covers the draft or its case; releasing the hold is itself recorded. The captured pre-ledger
preference store (R4) still holds a copy of migrated drafts, and the erasure reports how many such stores.
Erasure of documents, chunks, indexes and the vault for a person or case is not built yet (review L4).

## 4. Open decisions (owner / counsel)

1. **App Store privacy label.** N1 and N2 send content to a third-party AI service when the person turns them on.
   Whether that is "collection" under Apple's definitions, and what the label and `NSPrivacyCollectedDataTypes`
   must say, depends on that analysis and on the provider configuration. "Data Not Collected" is neither kept
   nor replaced here without it.
2. Apple's third-party-AI disclosure and permission, verified on the signed app (the preview and consent flow).
3. Roles (operator, customer, provider) and lawful grounds for sending third parties' information in a case file.
4. Required-reason APIs: SystemBootTime is declared but no matching call was found. The main app writes the App
   Group suite (reason 1C8F.1, not only CA92.1). DiskSpace is used only in DEBUG code. Share and Clipper have no
   privacy manifest.
