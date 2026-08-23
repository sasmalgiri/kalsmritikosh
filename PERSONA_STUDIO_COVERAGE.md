# Persona Studio Coverage — real-life deliverable ⇄ our workflow (2026-08-23)

The check the owner asked for: **every persona matched against its real-life
counterpart's end report/document, workflow steps matched to real life, the
hardcopy as the end goal, history presentable on demand, audit trail preserved.
None left out.**

## The matrix — 10 personas, 10 studios

| # | Persona | Real-life professional & their actual deliverable | Our studio (destination) | Real-life steps we mirror | The gates that make it faithful |
|---|---------|-----------------------------------------------------|--------------------------|---------------------------|--------------------------------|
| 1 | Investigator | Incident investigator: **RCA report (8D-style)** and intelligence analyst: **ACH workbook (Heuer)** | Reasoning Studio (`reasoning`) + Hypotheses/ACH (`hypotheses`) | Frame → brainstorm → 5 Whys → fishbone → conclusion → approval; matrix → diagnosticity → assessment | Dual root cause (occurrence + escape), cause→action linkage, approval sign-off, "ACH aids judgment, not a verdict" |
| 2 | HR / Compliance | Workplace investigator: **investigation report** | Workplace Studio (`hrStudio`) | Mandate → allegations → evidence → credibility → findings → report | Recommendations only if mandate authorises; notice + opportunity to respond; findings on the balance of probabilities with `FindingClassification` |
| 3 | Lawyer | Litigator: **FRCP 26(b)(5) privilege log** served on opposing counsel | Privilege Log Studio (`privilegeStudio`) | Matter → entries → QC → serve | Every entry has a basis (AC/WP); descriptions must not reveal content; certification printed |
| 4 | SIU | Insurance special investigator: **referral / disposition report** (NAIC #901 / NICB) | SIU Studio (`siuStudio`) | Claim → red flags → chronology → investigation → disposition | Red flags from objective criteria; "indicators are not proof" acknowledgment; external referral requires good-faith confirmation |
| 5 | Forensic Accountant | Testifying expert: **FRCP 26(a)(2)(B) expert report + tracing schedule** | Forensic Studio (`faStudio`) | Engagement → materials → method → schedule → opinion | Named tracing method (indirect requires justification); every transaction carries a source document; certainty declared |
| 6 | Journalist | Reporter/editor: **pre-publication fact-check memo + right-of-reply log** | Fact-Check Studio (`jnStudio`) | Story → claims → right of reply → memo | Any claim short of verified forces a reply entry (silence logged); alleged-labelling + corrections-path gates |
| 7 | Researcher | Evidence synthesiser: **PRISMA flow + extraction table + GRADE summary of findings** | Evidence Review Studio (`rsStudio`) | Protocol → screening → extraction → synthesis | Question fixed before screening; PRISMA funnel can only shrink; extraction rows must equal "included"; GRADE certainty required; conflicts shown, never averaged |
| 8 | Genealogist | Professional genealogist: **GPS proof argument** | Proof Argument Studio (`gnStudio`) | Question → research log → analysis & conflicts → proof | All five GPS elements: exhaustive search with NIL results logged, complete citations, correlation, conflicts resolved with reasoning, written conclusion |
| 9 | Content Creator | Professional publisher: **publish package / pre-publish checklist** | Publish Package Studio (`ccStudio`) | Piece → claims → rights & disclosures → package | Every claim checked to a named source; every third-party asset cleared; material connections (FTC-style) disclosed; corrections path confirmed |
| 10 | Individual | Professional organizer / estate planner: **family emergency binder** | Emergency Binder Studio (`inStudio`) | People → documents & accounts → instructions → binder | Every item needs a stated location (findability is the point); freshness review gate — a stale binder protects nobody |

## Hardcopy is the end goal — every studio

Every studio ends in a rendered markdown hardcopy that mirrors the professional
document's section order (asserted by an ordered-structure test per studio),
prefixed with the legal disclaimer, exportable three ways: **Copy · Export
Markdown · Print / Save as PDF**.

## History on demand + audit trail — every studio

- Every deliverable carries `history: [StudioAuditEntry]` — created, worked
  example loaded, report copied / exported / printed (the copy/export/print
  events are recorded by the shared shell used by studios 7–10; studios 1–6
  record creation and example-loading).
- **On demand:** the shell's toolbar has a History button (clock icon) showing
  the full event list; every studio's hardcopy prints the history as
  *"Appendix — Document history (audit trail)"*, so the trail travels with the
  document.
- **Preserved:** history is part of the persisted record (JSON), survives
  round-trips (tested), and records saved before the trail existed still decode
  (`history` is optional — tested against legacy JSON).
- Separately, the sealed Work Center findings pipeline keeps its own numbered
  documents, receipts, and review-desk audit — the report==receipt invariant is
  unchanged.

## Verification (2026-08-23)

- Build: green.
- Tests: 37/37 across all ten studios' suites, including the new
  `PersonaDeliverables2Tests` (stage gates, ordered hardcopy structure, JSON
  round-trips, audit-trail-on-every-hardcopy).
- Known remainder: studios 1–6 do not yet auto-record copy/export/print events
  (their creation + example events do appear); migrating them onto the shared
  shell would close that and is a small, mechanical follow-up.
