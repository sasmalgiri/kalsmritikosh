# ALCOA++ with Secure and Reliable — data-integrity program (owner, 2026-11-24)

The framework has 12 principles:

- Attributable, Legible, Contemporaneous, Original, Accurate (the ALCOA core);
- Complete, Consistent, Enduring, Available (the "+");
- Traceable (the "++", EMA 2023);
- Secure, Reliable (owner's additions).

**Wording rule:** we say "built on ALCOA++ principles, with Secure and Reliable", never "compliant". Formal compliance needs validation and real e-signatures.

The code audit of 2026-11-24 found the gaps below. Tracker rows DATA-11 … DATA-32 map to ALC-01 … ALC-22 in this order.

| ALC | Tracker | Principle | Gap | Fix |
|---|---|---|---|---|
| ALC-01 | DATA-11 | Accurate/Complete | AI records re-found after a document change stay withdrawn (keyDigest lacks the document fingerprint; INSERT OR IGNORE skips them) | Add the fingerprint to CaseAgent.keyDigest or restore on re-insert |
| ALC-02 | DATA-12 | Attributable | AI records carry no run id, model requested/served, request SHA-256, prompt version or requester; agent loop and picture write no case_ai_runs row; no approver | v210 columns + a run row per question/picture pass + an AI-record decision table (accept/reject with approver) |
| ALC-03 | DATA-13 | Accurate | Sum tool misreads comma-decimal amounts (€1.234,56 → 1.234); $ assumed USD, Rs INR; only 4 currencies | Locale-aware amountPattern; flag ambiguous symbols instead of guessing |
| ALC-04 | DATA-14 | Traceable | custody hash_verified / hash_mismatch / exported / disclosed never written (recordCustodyEvent has no callers) | Write them on vault open, reprocessing and export |
| ALC-05 | DATA-15 | Accurate/Secure | Plain-mode and already-opened vault copies returned without re-hash | Re-hash on every open; opened copies read-only |
| ALC-06 | DATA-16 | Enduring | Audit-chain HMAC secret is device-only and loadOrGenerate overwrites it, so the chain reads broken after restore or a new Mac | Derive from the ledger/recovery key (as backups do); never overwrite an existing secret |
| ALC-07 | DATA-17 | Traceable | Chain omits case_ai_records, case_ai_runs, outbound_log, source_versions, erasure registers, case_record_revisions; core logs have no append-only triggers | New chain sources + BEFORE UPDATE/DELETE triggers |
| ALC-08 | DATA-18 | Reliable | Relay server-side fallback to another model is unrecorded; served model not logged; no live-eval release gate | Log the served model per call; disable or label fallback on case reads; add a release gate that runs the fair eval before any model change |
| ALC-09 | DATA-19 | Complete | Answers don't say when the agent hit its step limit or token ceiling, or a picture part failed | Show 'stopped after N steps / ceiling reached / K documents not read' |
| ALC-10 | DATA-20 | Complete | In-place overwrites without triggers (studio_records, investigation_cases, case_allegation_evidence, investigation_hypotheses, deadlines, case_interviews, case_ai_picture_documents); no reason on case_record_revisions | Revision capture + triggers; reason column |
| ALC-11 | DATA-21 | Traceable | No view/read logging | Access events when cases, originals and exports are opened |
| ALC-12 | DATA-22 | Contemporaneous | No recorder time zone/clock source on log rows, no clock-jump detection, no trusted timestamp | recorded_tz + clock_source; wall time + uptime pairing with a jump check; RFC 3161 timestamps of the chain head and signed receipts through the network helper |
| ALC-13 | DATA-23 | Traceable | No per-case integrity pack | Data integrity report / pack export: chain check, custody, vault hashes, AI runs, outbound log, revisions, erasures, coverage |
| ALC-14 | DATA-24 | Traceable | AI reply bodies and tool results not kept | Store the encrypted reply + tool record per run (erased with the case) |
| ALC-15 | DATA-25 | Secure | Unlocked originals and captures staged as plain files in temp | Stage in the owner-only vault area and wipe, or seal |
| ALC-16 | DATA-26 | Available | No scheduled backup verify or practice restore; health check skips chain, vault and custody | Monthly automatic restore into a temp location with a kept result; add the three health checks |
| ALC-17 | DATA-27 | Original | No certified-copy statement on exports; clean_content overwritten in place | Certification page (hash, source version, producer); versioned cleaned text with cleaner version |
| ALC-18 | DATA-28 | Legible | Rejected AI writes and their reasons discarded; Ask transcripts hard-deleted | Keep rejected writes with the reason; retract transcripts (respect legal hold) |
| ALC-19 | DATA-29 | Consistent | Chronology dates use the device locale with no time zone label | One export date style with a stated zone |
| ALC-20 | DATA-30 | Enduring | No PDF/A; no retention rules for logs | PDF/A-2b output at sign-off; retention register per table class |
| ALC-21 | DATA-31 | Secure | No key rotation; exports not encrypted; capture GET allows any HTTPS host | Rotate-keys command re-sealing the vault; optional export encryption; capture limited to hosts the person named |
| ALC-22 | DATA-32 | Accurate/Reliable | FAIR2 checker bugs: '03 Aug 26' and dd/mm misread; 'one hundred percent' not 100; 'two INR 50,000' counted as a number; quotes under 12 characters dropped | Fix VerifiedAnswerComposer.values(in:role:) and whyNot |

**What is already strong:** custody SHA-256 at intake, a sealed vault, immutable source versions, the HMAC audit chain, the case log, a once-per-case permission, name masking, the PrivacyGate and network-helper door, an SQLCipher ledger, erasure with legal hold and tombstones, and the per-answer proof bundle.
