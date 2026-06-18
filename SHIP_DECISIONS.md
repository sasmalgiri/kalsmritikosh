# kalsmritikosh — Ship Decisions (LOCKED)

Decisions captured 18 Jun 2026. Treat each row as a contract: when a future engineering question's answer would contradict one of these, the decision wins unless explicitly revisited and updated here.

The point of this file is to stop scope creep and re-debating decided things. If something feels uncertain, check here first.

---

## Product

| Decision | Pick | Implication |
|---|---|---|
| **Buyer persona** | Privacy-first, all personas | Headline leads with privacy, not workflow vertical. Demo must work for lawyer + researcher + archivist + curious individual without changing copy. |
| **Distribution path** | Mac App Store | Apple handles payment, 15-30% cut. No license server to build. App Sandbox mandatory (✓ already configured). Apple review process required. |
| **Pricing** | $29-$49 one-time (Personal tier) | Serious-tool benchmark. Pro tier reserved for later (corpus size / export / advanced reconstruction differentiators TBD). |
| **Launch timeline** | No deadline | Quality-driven, not calendar-driven. Risk shifts from "missing date" to "scope inflation" — this doc is the scope inflation control. |
| **Ship bar (v1.0)** | Set C — confident v1.0 | See "Ship gates" below. The bar is not negotiable downward without revising this row. |

## Engine direction

| Decision | Pick | Implication |
|---|---|---|
| **Reasoning model strategy** | Must bundle on-device | `LlamaCppProvider` (currently stub) must be unstubbed. No "install Ollama" friction for end users. Model name continues to live ONLY in `App/AppState.swift` per the architecture invariant. |
| **Answer UX** | G2-PROGRESSIVE — instant → stream → deep → verified | Spec in `GATE2_ROADMAP.md`. Visible trust contract: every phase shows its state tag in the bubble (`🕒 Quick read · verifying…` → `✎ Synthesizing…` → `🔍 Reading sources…` → Quality Strip locked). |
| **Engine state at Gate 1 lock** | Partial G2-0 rollback (`7b23986`) | Shared retrieval kept (~15× wall-clock win on temporal/multihop). WorkerPool reverted 8→4. Multihop recall regressed to 0.54 vs Gate 1 lock 0.67 — accepted because the wall-clock win unblocks all subsequent G2 work; recall expected to recover with G2-1 reranker. |
| **Toggle for users** | Fast/Accurate switch in Settings (deferred) | Lets users choose retrieval mode at query time. Spec to be drafted as a small Gate 2 item if precision/recall trade remains visible after G2-1. |

## Ship gates (must ALL be true before App Store submission)

These derive from "Set C" but are restated here as binary checks:

- [ ] Bundled on-device reasoning model — no Ollama install required
- [ ] Lookup citation precision ≥ 0.8 (currently 0.33, gap closed by G2-1 reranker)
- [ ] Aggregation keyword-hit ≥ 0.8 (currently 0.50, gap closed by reranker + contextual retrieval + stronger bundled model)
- [ ] Multi-hop retrieval recall ≥ 0.6 (currently 0.54 in partial G2-0, must recover to 0.67+)
- [ ] Eval corpus expanded from 16 → 60 questions; numbers above re-verified at N=60
- [ ] 1 TB real-archive stress test passes (ingestion completes, query latency holds, memory bounded) — requires G2-INGEST (two-pass + per-folder OCR opt-in)
- [ ] PrivacyInfo.xcprivacy manifest present
- [ ] Privacy Policy URL hosted, linked
- [ ] Terms of Use / EULA hosted, linked
- [ ] 10 real beta users tested on their own archives; ≥ 7 say "I'd recommend it"
- [ ] App Store metadata complete: name, subtitle, keywords, description, screenshots (no PII), category, age rating, privacy nutrition labels
- [ ] Clean-machine install test passes on minimum hardware (see Open below)

## Out of scope for v1.0 (defer to v1.x)

- Pro tier definition and pricing
- Direct DMG distribution (App Store only at launch)
- Cloud-routed model option (privacy promise rules this out for v1; could revisit as opt-in)
- Multi-language UI (English only)
- iOS / iPad companion
- Legacy Office binaries (.doc, .xls, .ppt) — Gate 3
- Microsoft Publisher (.pub) — never planned
- PST/OST/MSG/NSF email formats (GS-MAIL block in TASKS.md, Gate 3)

## Open (still to decide)

- Minimum hardware floor (RAM, OS — macOS 15.6 locked, but RAM TBD)
- v1 vs v1.1 / v2 specific feature cuts (beyond Set C metrics)
- Killer demo question for App Store screenshots
- Beta tester recruitment plan (10 names)
- One-sentence positioning pitch (owner-only; planning thread held this rail)
- Pro tier differentiators

---

Last updated: 18 Jun 2026 — alongside Gate 1 baseline lock (`4bcf4e5`) + G2-0 partial rollback (`7b23986`) + G2-PROGRESSIVE spec (`e9486e9`).
