# Persona job-fit — what works, what's missing, what to build

Grounded in a code audit (not assumptions). The headline correction: **ingest
coverage is strong** — audio *and* video are transcribed on-device, scans are
OCR'd, and email/Outlook/Notes/chat/browser all ingest. So the persona blockers
are **not** file formats; they're in analysis depth + a few workflow pieces.

Status legend: ✅ works · ⚠️ partial · ❌ missing.

## Cross-cutting (helps every persona)

| Capability | Status | Gap → build |
|---|---|---|
| Cited answers, export, timeline, entity graph, dossiers | ✅ | — |
| Ingest: PDF/Office/email/images/**audio/video**/chat/browser | ✅ | (legacy .doc/.xls/.ppt lossy; .key/.rar/.7z stubs — low priority) |
| **Contradiction detection** | ⚠️ date-only | statement + entity/amount conflicts (big value for Lawyer/Investigator/Journalist) |
| **Audio/video citations** | ⚠️ transcribed but **no timecodes** | write ASR segment timings into `transcript_segments` so answers can cite "at 12:34" — directly serves call recordings / interviews |
| **Entity dedup / merge-split** | ⚠️ OCR-variant folding only | real "same person, two spellings" merge (Investigator/Researcher) |
| **Missing-evidence gaps** | ⚠️ taxonomy exists, rules partial | finish gap rules (Lawyer/Investigator) |

## 1. Lawyer
**Jobs:** case chronology · what's proven vs missing · contradictions · privileged/redacted exhibits · cited work product.
- ✅ chronology, citations, export, date-contradictions, reject/restore facts.
- ⚠️ **Contradiction** is date-only — misses "he said X / she said not-X" and amount conflicts.
- ❌ **Redaction UI (F7)** — the redact engine exists but there's **no UI to define rules**. *Safety-critical: shipping a redactor that silently misses PII gives false confidence — must be blind-run-tested before enabling.*

## 2. Investigator
**Jobs:** who-knew-what-when · connections · corroboration · gaps · recordings.
- ✅ timeline, entity graph, dossier, single-source flags, **call/interview recordings ingest**.
- ⚠️ **No timecodes** on recordings → can't cite the exact moment in a call. (highest-value, cleanly buildable)
- ⚠️ relationship graph is coarse (Tier-1 co-occurrence); causal links partial.

## 3. Journalist
**Jobs:** verify claims · what conflicts · what's corroborated · re-run as new docs arrive.
- ✅ corroboration counts, saved questions, search, citations.
- ⚠️ contradiction depth (same as Lawyer) — the core "where do sources conflict" job.
- ⚠️ narrative reconstruction is partial.

## 4. Researcher
**Jobs:** reconstruct a period · known vs inferred · browse corpus · uncertain dates · bibliography.
- ✅ history/narrative, library, date-precision timeline, corpus stats, export.
- ⚠️ **corpus-wide entity dedup** (same author, many spellings) — noise at scale.
- ⚠️ no disk-backed vector index yet → very large (100GB) corpora degrade (P9.3).

## 5. Everyone
**Jobs:** ask · search · remember.
- ✅ all core paths work with the persona workbench.
- ⚠️ AI answers require Apple Intelligence (macOS-gated) — evidence/search work without it, but a "no-LLM" mode message helps.

## Recommended build order (one persona job at a time)

1. **Audio/video timecodes** → Investigator + Journalist. Wire SFSpeech segment
   timings into `transcript_segments`; answers cite "in recording.m4a at 12:34".
   Self-contained, high value, verifiable. **← start here.**
2. **Statement + amount contradiction detection** → Lawyer + Journalist +
   Investigator. Extend the verifier beyond dates.
3. **Entity merge/split review** → Investigator + Researcher.
4. **Missing-evidence gap rules** → Lawyer + Investigator.
5. **Redaction UI (F7)** → Lawyer. *Gated on a blind-run PII test first (safety).* 
6. Later/large: disk-backed ANN for 100GB (P9.3); richer causal graph.

Each is a scoped, buildable unit — we do them one by one, verifying on real data.
