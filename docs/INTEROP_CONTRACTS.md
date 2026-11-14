<!-- GENERATED from Kalsmritikosh/App/InteropContracts.swift; do not edit by hand. Regenerate: HelpRegistryTests.interopContractsMatch (console) + scripts/help-docs-from-console.py -->
# Interoperability contracts

What the app exchanges with other products and formats — each adapter's version and field contract, what happens to a missing field or a changed version, the tests that exercise it, and its limits. Anything not listed here is not supported. Passing on a sample is not universal compatibility.

## Adapters

| Adapter | Family | Formats | Tested versions | Fields | Version rule | Tests | Limits |
|---|---|---|---|---|---|---|---|
| Structured exchange | Records and relationships (import and export) | ime-case-exchange JSON, UTF-8 (BOM tolerated) | 1 | Top: format, version, sourceSystem required; records[]: id, kind (question, person, event), text required, date, role, sources[] {sourceVersionID, quote} optional; relationships[]: id, type, from, to required, rationale, certainty optional. A record or relationship missing a required field is skipped and named in the receipt; any other field is reported as unsupported. | Any version other than 1, another format name, non-UTF-8 or non-JSON bytes: refused before anything is written. | SmartMapS12Tests.exchangeRoundTrip, SmartMapS12Tests.adapterFailureModes | Documents, money, tasks, reports and decisions are not part of the format. Source references import only when that source version is in the case. |
| Cellebrite UFDR / Reader report | Forensic (mobile extraction reports) | .ufdr (ZIP holding report.xml) or an unzipped report folder | Report XML read by mapper version 1, against the synthetic fixtures in TeamsCellebriteImportTests (no vendor sample of a named Cellebrite release) | Chats, messages (sender, timestamp, body, attachments), calls (direction, duration, status, parties), contacts, top-level SMS. A missing field is left empty, never filled in; an unmapped model type is counted and reported. | A malformed or unexpected report keeps what was read and says where it stopped; a zone-less time stamp is recorded undated with a warning. | TeamsCellebriteImportTests.ufdrChatMessages, TeamsCellebriteImportTests.ufdrMalformedReport | Tested on synthetic reports only. No claim of compatibility with any specific Cellebrite product release. |
| Microsoft Teams export | Email and messaging | messages.json (object or array-of-conversations root) | The export shape in TeamsCellebriteImportTests fixtures | Conversation id, message sender, account id, arrival time, content (HTML stripped). Non-text entries are skipped and counted; missing fields are tolerated and left empty. | An unrecognised root is not routed to the messaging lane; it is read as plain JSON. | TeamsCellebriteImportTests.teamsArrayRoot, TeamsCellebriteImportTests.teamsNonTextCounted | Tested on fixtures shaped like Microsoft's export; not against every tenant export version. |
| Bank statement rows | Financial (tabular) | Pasted or CSV text with a header row naming a date column and debit/credit columns | The header forms in SmartMapS7Tests | Date (only yyyy-mm-dd becomes a day; any other form is kept as written; a row with no date is refused), debit or credit (a zero, a dash or a blank is no amount; a row with neither, or with both, is refused and named; an opening, closing, balance or total line is refused), description, reference. Comma-separated text is read as RFC 4180 (quoted cells), with CRLF, CR or LF line ends; every row is written in one savepoint. | A header without a date and a debit/credit column is refused; nothing is imported. | SmartMapS7MoneyTests.statementsRatesAndGaps, DeepDiveBatch3Tests.statementImport | No bank-specific statement format is claimed; amounts are read exactly as written. |
| Email (MBOX, EML, EMLX) | Email | RFC 5322 messages; mbox files; Apple Mail .emlx | As listed and measured in CAPABILITY_MATRIX.md | Headers, bodies and attachments as listed there; unreadable parts are marked unreadable. | See SUPPORTED_SOURCES.md; Outlook MSG/PST are kept but not read. | AllDomainSyntheticMatrixTests.capabilityMatrixIsMeasured | Outlook stores are preserved only (ADAPT-05: attach a supplied summary). |
| Case map relationship table | Records and relationships (export only) | CSV (and the PDF/PNG map with the same table); read-only HTML case package | The current table columns | Every drawn link with its type, ends, why it exists and its sources. | Export only; there is no import of this table. | SmartMapS11Tests.packageWholeCase | For reading in other tools; it is not a round-trip format (use the structured exchange). |

## External enrichment connectors

| Connector | Status | Prerequisite |
|---|---|---|
| Sanctions lists (OFAC, UN) | Available in Online mode: lists downloaded and searched on this Mac; results are leads with match status (match, no match, failed). | Online mode on; no key. |
| Company registry (GLEIF) and court records (CourtListener) | Available in Online mode as lookups; results are leads, not imported as case records. | Online mode on; the name searched is sent to that service. |
| Commercial people, company and corporate-ownership data providers | BLOCKED — not implemented. | A provider chosen by the owner, its subscription and API key, its terms reviewed; then a typed adapter returning candidate records with origin, retrieval time, scope, pages, cost and restrictions, routed to review. |
| Maltego-style transforms and repeatable enrichment recipes | BLOCKED — not implemented. | The paid providers above; recipes would run under case automation's policy, budgets and review checkpoints. |

## Named products

| Product | Support | Note |
|---|---|---|
| Cellebrite (UFDR / Reader report) | Import of report XML (mapper version 1), synthetic fixtures only | No specific Cellebrite release is claimed. |
| Microsoft Teams | Import of messages.json exports (fixtures) | Not tested against every tenant export version. |
| i2 Analyst's Notebook | None | No import or export of .anb/.anx. The relationship table (CSV) can be read by tools that read CSV; that is not i2 compatibility. |
| Maltego | None | No transforms, no import or export of Maltego graphs. No parity is claimed. |
| DataWalk | None | No integration. No parity is claimed. |
| Casefleet | None | No integration. Chronology and fact records are this app's own. No parity is claimed. |
| Palantir | None | No integration. No parity is claimed. |
| DEVONthink | Companion bridge (import of a DEVONthink package; Send to DEVONthink) | As described in Help ▸ DEVONthink; not part of the exchange format. |

