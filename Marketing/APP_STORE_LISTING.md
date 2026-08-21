# App Store Listing — Kalsmritikosh (draft)

> Draft marketing copy + submission checklist. Adjust brand voice, pricing, and
> claims to taste. Keep claims honest (the app is careful about this in-product).

## Names
- **App name (30 char max):** Kalsmritikosh
- **Subtitle (30 char max):** Private evidence workbench
  - alt: "Your archive, made answerable"

## Promotional text (170 char, updatable without review)
Turn your whole document and email archive into answers you can trust —
timelines, dossiers, datasets — every fact cited to its source. Fully on-device.

## Description
Kalsmritikosh turns your private document and email archive into a structured,
answerable knowledge base — entirely on your Mac, with nothing sent to the cloud.

It doesn't just chat with your files. It builds a real ledger — people, dated
events, relationships, a timeline, distilled memory — and answers questions
through specialist experts behind an evidence gate. Every claim carries the
exact sources behind it; conflicts are shown, not averaged away.

BUILT FOR SERIOUS WORK
• Ask in plain language — answers cite their evidence, with confidence and gaps
• Timelines, dossiers, and "what changed" as new documents arrive
• DataLab — build cited datasets over your evidence, or generate them straight
  from what you've ingested (timelines, people, payments, communications,
  conflicts, missing evidence); every cell drills back to its source
• Professional Work Center — step-by-step workflows for real jobs
• Real redaction that removes text (not a black box you can undo)
• File authenticity signals, layered citations, fund-flow view, email threading

PRIVATE BY DESIGN
• Runs fully on-device — your documents, the knowledge, and your questions never
  leave your Mac
• No analytics, no telemetry, no cloud processing
• Delete everything by removing the app's data

HONEST BY DESIGN
Kalsmritikosh is a tool, not professional advice. It shows what's proven, what's
inferred, and what's missing — and tells you when it isn't sure.

[Add: supported formats, system requirements, pricing/trial.]

## Keywords (100 char, comma-separated, no spaces)
evidence,timeline,archive,private,on-device,research,legal,investigation,notes,documents,ai,dossier

## Support / marketing URLs
- Support URL: [https://yourdomain.com/support]
- Marketing URL: [https://yourdomain.com]
- Privacy Policy URL (required): [https://yourdomain.com/privacy]

## App Privacy ("nutrition label") answers
- Data collected: **None** (no data collected). Confirm the optional model
  download sends no user content; declare accordingly.
- Tracking: **No.**

## Export compliance
- Uses encryption? Add `ITSAppUsesNonExemptEncryption` to Info.plist.
  - If only standard OS/HTTPS + hashing (SHA-256) is used → typically **exempt**
    → set the key to `false`. Confirm with counsel/Apple guidance.

## Age rating
- Likely 4+ (no objectionable content). Confirm via the App Store questionnaire.

---

## The 10 screenshots — shot list + specs
> I can't capture these to store quality from here (they need the running app on
> real/fixture data at Apple's resolutions). Capture with Product ▸ Run, load the
> ProjectDelta fixture (or your own archive), then screenshot. **Mac App Store
> sizes:** 1280×800, 1440×900, 2560×1600, or 2880×1800 (16:10). Provide at least
> one; up to 10. My rendered SwiftUI previews (in the build artifacts) can be
> layout references.

1. **Ask** — a question with a cited, confidence-graded answer (the hero shot).
2. **Timeline** — reconstructed dated events across the archive.
3. **DataLab — build from evidence** — the "Build from evidence" menu open
   (Timeline / People / Payments / Communications / Conflicts / Missing evidence).
4. **DataLab — a sourced dataset** — green, drill-through-bound cells (provenance).
5. **Fund Flow** — the payer→payee Sankey with the ranked flow list.
6. **Work Center** — a persona workflow mid-run (gated steps + guidance).
7. **Redaction** — the "Verified — no matching text remains" result card.
8. **Findings / Freshness** — facts by status, or the freshness monitor.
9. **Privacy** — Settings → Legal & Privacy ("private by design", on-device).
10. **Professional Jobs** — the persona picker (breadth of who it's for).

Caption each with a one-line benefit. Keep every visual claim consistent with
the honest in-app framing (no "guaranteed", no "detects fakes").
