# Kalsmritikosh — App Store Listing (draft)

_Draft copy + review notes for App Store Connect (REL-005). Owner fills the bracketed items,
adds screenshots, and submits. Every claim below is deliberately kept within the "Do NOT claim"
list of the release spec (§6) and the locked contract in `SHIP_DECISIONS.md`. Last reviewed
2026-07-22._

## Metadata

- **Name:** Kalsmritikosh
- **Subtitle (≤30 chars):** `Private, cited answers on-device`
- **Category:** Productivity (secondary: Reference)
- **Age rating:** 4+ (no objectionable content; user supplies their own files)
- **Price:** One-time purchase _(owner sets tier)_. No subscriptions, no in-app purchases.
- **Keywords (≤100 chars):**
  `documents,email,search,evidence,timeline,on-device,private,archive,pdf,notes,offline,citations`

## Promotional text (≤170 chars)

> Turn your own documents and email into a private, searchable knowledge base — with answers that
> cite their sources. Everything runs on your Mac. Nothing leaves your device.

## Description

> **Kalsmritikosh is a private, on-device workspace for your own archive.**
>
> Point it at your folders of documents and email. It builds a structured record — people,
> dates, events, facts — and lets you ask questions and get answers that **cite the exact source
> passages** they came from. When the evidence isn't there, it tells you honestly instead of
> guessing.
>
> **Private by design.** Everything runs on your Mac. There's no account, no sign-in, and no
> analytics. Your files and questions never leave your device.
>
> **What you can do**
> • Search and ask questions across everything you've added — answers come with clickable citations.
> • Build timelines and see how events connect across sources.
> • Surface contradictions and gaps between documents.
> • Organize evidence into workspaces and export cited work products.
> • See exactly what's been processed, and what couldn't be, with honest per-source coverage.
>
> **Rich answers use Apple's on-device intelligence** where your Mac supports it; everywhere else
> the app still works fully in a deterministic mode (search, timelines, matrices, contradictions,
> gaps, and cited reports).
>
> **Supported files** include common document, spreadsheet, presentation, email, image (with text
> recognition), and structured-data formats. Some formats are supported with limits and are shown
> honestly in-app; audio and video are catalogued and preserved at ingest (never auto-transcribed) — transcribe individual files on demand in Transcripts, fully on-device (Apple Speech, English).
>
> _Kalsmritikosh is an informational aid. Verify important answers against the cited originals; it
> is not legal, financial, or professional advice._

## Privacy nutrition labels

- **Data Not Collected.** No data is collected, tracked, or linked to the user. No account.

## URLs

- **Privacy URL:** https://sasmalgiri.github.io/kalsmritikosh/privacy.html
- **Support URL:** https://sasmalgiri.github.io/kalsmritikosh/support.html
- **Terms/EULA:** https://sasmalgiri.github.io/kalsmritikosh/terms.html (Apple's standard LEULA also applies where no custom EULA is presented)

## Screenshots (plan — capture on a demo corpus with NO real PII)

1. **Ask** — a question with a cited answer + quality strip (confidence/sources).
2. **Sources** — folders added, with the multi-dimensional readiness strip (parsed/embedded).
3. **Timeline** — dated events reconstructed from evidence.
4. **A work product / report** — sections with claims and citations.
5. **Cross-document matrix or contradictions** — evidence compared across sources.

Use the demo corpus in `Resources/Fixtures/ProjectDelta` (synthetic — safe for screenshots).

## Review notes (paste into App Review Notes)

> Kalsmritikosh is a **local evidence/archive workspace**. It processes only files the user
> explicitly selects via macOS security-scoped folder access. **No account is required** and
> **core processing is on-device**; the release build contains no network provider and sends no
> data off the device. Rich answers use Apple's on-device Foundation Models on supported macOS 26+
> hardware; on macOS 15.6–25 the app runs in a deterministic, no-model mode.
>
> **To demo:** launch → Sources → add the included demo folder (or any folder of documents) →
> "Ingest All" → open **Ask** and enter a question → the answer appears with clickable source
> citations. Work products export from the Studio/report screens.
>
> **No hidden purchases** (one-time price). **No model download** in this version. Minimum OS
> macOS 15.6; AI-written answers require macOS 26+ with Apple Intelligence on supported hardware.

## Do-NOT-claim checklist (verified against this copy)

- [x] Does not claim *every* format (says "common … formats", "some with limits").
- [x] Does not claim legal admissibility (explicit "not legal advice / verify against sources").
- [x] Does not claim full video understanding (says audio/video are preserved at ingest; transcription is on-demand, on-device, English-only in this version).
- [x] Does not claim 1 TB / unlimited scale (no scale number in copy; store page uses tested figure).
- [x] Does not claim a bundled reasoning model (says Apple on-device where supported, else deterministic).
- [x] Does not claim "no network" falsely (accurate: release has no network provider, no downloader in v1).
- [x] Zero-data-collection claim is accurate (no telemetry/analytics/account exist).
