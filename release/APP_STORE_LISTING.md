# Kalsmritikosh — App Store Listing (draft)

_Draft copy + review notes for App Store Connect (REL-005). Owner fills the bracketed items,
adds screenshots, and submits. Every claim below is deliberately kept within the "Do NOT claim"
list of the release spec (§6) and the locked contract in `SHIP_DECISIONS.md`. Last reviewed
2026-10-17 (Online mode, ledger encryption, Share/Services capture, DEVONthink bridge, iPhone/iPad
viewer added)._

## Metadata

- **Name:** Kalsmritikosh
- **Subtitle (≤30 chars):** `Private, cited answers on-device`
- **Category:** Productivity (secondary: Reference)
- **Age rating:** 4+ (no objectionable content; user supplies their own files)
- **Price:** One-time purchase in the $29–49 band — recommended tier **$39** _(owner confirms in App Store Connect)_. No subscriptions, no in-app purchases.
- **Export compliance:** declared in the build (`ITSAppUsesNonExemptEncryption = NO` — Apple OS crypto only; SHIP_DECISIONS 2026-10-17).
- **Keywords (≤100 chars):**
  `documents,email,search,evidence,timeline,on-device,private,archive,pdf,notes,offline,citations`

## Promotional text (≤170 chars)

> Turn your own documents and email into a private, searchable knowledge base — with answers that
> cite their sources. Private by default: everything runs on your Mac, encrypted.

## Description

> **Kalsmritikosh is a private, on-device workspace for your own archive.**
>
> Point it at your folders of documents and email. It builds a structured record — people,
> dates, events, facts — and lets you ask questions and get answers that **cite the exact source
> passages** they came from. When the evidence isn't there, it tells you honestly instead of
> guessing.
>
> **Private by design.** Everything runs on your Mac, and the knowledge base is encrypted on
> disk. There's no account, no sign-in, and no analytics. By default your files and questions
> never leave your device. If you choose, connect your own cloud AI key — you'll see exactly
> what would be sent before anything leaves your Mac.
>
> **What you can do**
> • Search and ask questions across everything you've added — answers come with clickable citations.
> • Build timelines and see how events connect across sources.
> • Surface contradictions and gaps between documents.
> • Organize evidence into workspaces and export cited work products.
> • See exactly what's been processed, and what couldn't be, with honest per-source coverage.
> • Works beside DEVONthink: import a DEVONthink database in place, send items back to it.
> • Save to Kalsmritikosh from the Share and Services menus in Safari, Mail, Finder and more.
> • Scan a document or take a photo with your iPhone or iPad straight into your archive (Continuity Camera).
> • Write your own notes in Markdown — searchable, with every earlier version kept.
> • Automate with Shortcuts and AppleScript.
> • Use it beside DEVONthink, or on its own: one switch turns on tags, highlights, smart collections and the other organising tools.
> • Arrange documents in your own folders — one document can live in several at once — and see what else in your archive is alike, with suggestions for where to file it.
> • Highlight, underline and comment on PDFs without changing the original; export a marked copy.
> • Clip any page from Safari: the page, your selection, or a clean Markdown copy.
> • Keep your Macs and your iPhone or iPad in step through a folder you choose (iCloud Drive, Dropbox, a disk), encrypted with your passphrase. Scan paper on your phone straight into your archive.
> • Take a signed, read-only snapshot to your iPhone or iPad with the companion viewer.
>
> **Rich answers use Apple's on-device intelligence** where your Mac supports it; everywhere else
> the app still works fully in a deterministic mode (search, timelines, matrices, contradictions,
> gaps, and cited reports).
>
> **Supported files** include common document, spreadsheet, presentation, email, image (with text
> recognition), and structured-data formats. Some formats are supported with limits and are shown
> honestly in-app; audio and video are catalogued and preserved at ingest (never auto-transcribed) — transcribe individual files on demand in Transcripts, fully on-device (Apple Speech, English).
> Workflows cite US and international instruments; procedures are jurisdiction-neutral and deviations are recorded on the certificate.
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
> **core processing is on-device**. The app starts in **Private mode**, in which it makes no network
> connections at all; its knowledge base is encrypted at rest with a key kept in the Keychain.
>
> **Online mode (optional, off by default).** Settings ▸ Modules ▸ Connection ▸ Online. The user
> enters their own API key for Anthropic, OpenAI or Google Gemini. Before any text is sent, a
> consent screen shows the exact text, the destination host and its size; nothing is sent unless
> the user presses Send. Network access is confined to the bundled, sandboxed extension
> KalsmritikoshNetworkHelper, which may only make HTTPS requests to those three hosts; the main
> app has no network entitlement. To test: switch to Online, enter a key, ask a question, and
> observe the consent screen. Rich answers use Apple's on-device Foundation Models on supported macOS 26+
> hardware; on macOS 15.6–25 the app runs in a deterministic, no-model mode.
>
> **To demo:** launch → Sources → add the included demo folder (or any folder of documents) →
> "Ingest All" → open **Ask** and enter a question → the answer appears with clickable source
> citations. Work products export from the Studio/report screens.
>
> **No hidden purchases** (one-time price). **No model download** in this version. Minimum OS
> macOS 15.6; AI-written answers require macOS 26+ with Apple Intelligence on supported hardware.
> Workflows cite US and international instruments; procedures are jurisdiction-neutral and
> deviations are recorded on the certificate.

## Do-NOT-claim checklist (verified against this copy)

- [x] Does not claim *every* format (says "common … formats", "some with limits").
- [x] Does not claim legal admissibility (explicit "not legal advice / verify against sources").
- [x] Does not claim full video understanding (says audio/video are preserved at ingest; transcription is on-demand, on-device, English-only in this version).
- [x] Does not claim 1 TB / unlimited scale (no scale number in copy; store page uses tested figure).
- [x] Does not claim a bundled reasoning model (says Apple on-device where supported, else deterministic).
- [x] Does not claim "no network" falsely (accurate: Private mode — the default — makes no connections; Online mode is opt-in, user-keyed and consented per send; no downloader).
- [x] Zero-data-collection claim is accurate (no telemetry/analytics/account exist).
