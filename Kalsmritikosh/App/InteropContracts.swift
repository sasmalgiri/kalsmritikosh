//
//  InteropContracts.swift
//  Kalsmritikosh
//
//  Smart-map S12 (ADAPT-04 / ADAPT-07 / ADAPT-09) — the bounded record of what the app can exchange with other products and
//  formats, and nothing more. Each adapter states its version/field contract, what happens to a missing field or a
//  changed version, the tests that exercise it, and its limits. The named-product matrix says plainly which products have
//  NO integration, so describing a family of capabilities never becomes a claim of compatibility or parity. External
//  enrichment connectors are listed with their real prerequisites (provider keys, subscriptions) and stay blocked until
//  those exist. Rendered to docs/INTEROP_CONTRACTS.md; HelpRegistryTests.interopContractsMatch keeps the file in step.
//

import Foundation

public nonisolated enum InteropContracts {

    public struct Adapter: Sendable, Equatable {
        public let name: String
        public let family: String
        /// Formats, extensions and the version(s) actually tested.
        public let formats: String
        public let testedVersions: String
        /// Fields the adapter requires, and what it does with each missing one.
        public let fields: String
        /// What a changed or unknown version does.
        public let versionRule: String
        /// The test suites that exercise it (Suite.test).
        public let tests: [String]
        public let limits: String
    }

    public static let adapters: [Adapter] = [
        Adapter(name: "Structured exchange", family: "Records and relationships (import and export)",
                formats: "ime-case-exchange JSON, UTF-8 (BOM tolerated)", testedVersions: "1",
                fields: "Top: format, version, sourceSystem required; records[]: id, kind (question, person, event), text required, date, role, sources[] {sourceVersionID, quote} optional; relationships[]: id, type, from, to required, rationale, certainty optional. A record or relationship missing a required field is skipped and named in the receipt; any other field is reported as unsupported.",
                versionRule: "Any version other than 1, another format name, non-UTF-8 or non-JSON bytes: refused before anything is written.",
                tests: ["SmartMapS12Tests.exchangeRoundTrip", "SmartMapS12Tests.adapterFailureModes"],
                limits: "Documents, money, tasks, reports and decisions are not part of the format. Source references import only when that source version is in the case."),
        Adapter(name: "Cellebrite UFDR / Reader report", family: "Forensic (mobile extraction reports)",
                formats: ".ufdr (ZIP holding report.xml) or an unzipped report folder", testedVersions: "Report XML read by mapper version 1, against the synthetic fixtures in TeamsCellebriteImportTests (no vendor sample of a named Cellebrite release)",
                fields: "Chats, messages (sender, timestamp, body, attachments), calls (direction, duration, status, parties), contacts, top-level SMS. A missing field is left empty, never filled in; an unmapped model type is counted and reported.",
                versionRule: "A malformed or unexpected report keeps what was read and says where it stopped; a zone-less time stamp is recorded undated with a warning.",
                tests: ["TeamsCellebriteImportTests.ufdrChatMessages", "TeamsCellebriteImportTests.ufdrMalformedReport"],
                limits: "Tested on synthetic reports only. No claim of compatibility with any specific Cellebrite product release."),
        Adapter(name: "Microsoft Teams export", family: "Email and messaging",
                formats: "messages.json (object or array-of-conversations root)", testedVersions: "The export shape in TeamsCellebriteImportTests fixtures",
                fields: "Conversation id, message sender, account id, arrival time, content (HTML stripped). Non-text entries are skipped and counted; missing fields are tolerated and left empty.",
                versionRule: "An unrecognised root is not routed to the messaging lane; it is read as plain JSON.",
                tests: ["TeamsCellebriteImportTests.teamsArrayRoot", "TeamsCellebriteImportTests.teamsNonTextCounted"],
                limits: "Tested on fixtures shaped like Microsoft's export; not against every tenant export version."),
        Adapter(name: "Bank statement rows", family: "Financial (tabular)",
                formats: "Pasted or CSV text with a header row naming a date column and debit/credit columns", testedVersions: "The header forms in SmartMapS7Tests",
                fields: "Date (only yyyy-mm-dd becomes a day; any other form is kept as written), debit or credit (a row with neither is refused and named), description, reference.",
                versionRule: "A header without a date and a debit/credit column is refused; nothing is imported.",
                tests: ["SmartMapS7MoneyTests.statementsRatesAndGaps"],
                limits: "No bank-specific statement format is claimed; amounts are read exactly as written."),
        Adapter(name: "Email (MBOX, EML, EMLX)", family: "Email",
                formats: "RFC 5322 messages; mbox files; Apple Mail .emlx", testedVersions: "As listed and measured in CAPABILITY_MATRIX.md",
                fields: "Headers, bodies and attachments as listed there; unreadable parts are marked unreadable.",
                versionRule: "See SUPPORTED_SOURCES.md; Outlook MSG/PST are kept but not read.",
                tests: ["AllDomainSyntheticMatrixTests.capabilityMatrixIsMeasured"],
                limits: "Outlook stores are preserved only (ADAPT-05: attach a supplied summary)."),
        Adapter(name: "Case map relationship table", family: "Records and relationships (export only)",
                formats: "CSV (and the PDF/PNG map with the same table); read-only HTML case package", testedVersions: "The current table columns",
                fields: "Every drawn link with its type, ends, why it exists and its sources.",
                versionRule: "Export only; there is no import of this table.",
                tests: ["SmartMapS11Tests.packageWholeCase"],
                limits: "For reading in other tools; it is not a round-trip format (use the structured exchange)."),
    ]

    /// External enrichment connectors (ADAPT-07): what each would need. None runs without the prerequisite.
    public struct Connector: Sendable, Equatable {
        public let name: String
        public let status: String
        public let prerequisite: String
    }

    public static let connectors: [Connector] = [
        Connector(name: "Sanctions lists (OFAC, UN)", status: "Available in Online mode: lists downloaded and searched on this Mac; results are leads with match status (match, no match, failed).",
                  prerequisite: "Online mode on; no key."),
        Connector(name: "Company registry (GLEIF) and court records (CourtListener)", status: "Available in Online mode as lookups; results are leads, not imported as case records.",
                  prerequisite: "Online mode on; the name searched is sent to that service."),
        Connector(name: "Commercial people, company and corporate-ownership data providers", status: "BLOCKED — not implemented.",
                  prerequisite: "A provider chosen by the owner, its subscription and API key, its terms reviewed; then a typed adapter returning candidate records with origin, retrieval time, scope, pages, cost and restrictions, routed to review."),
        Connector(name: "Maltego-style transforms and repeatable enrichment recipes", status: "BLOCKED — not implemented.",
                  prerequisite: "The paid providers above; recipes would run under case automation's policy, budgets and review checkpoints."),
    ]

    /// Named products (ADAPT-09): what is and is not supported. Describing a capability family is not compatibility.
    public struct Product: Sendable, Equatable {
        public let product: String
        public let support: String
        public let note: String
    }

    public static let products: [Product] = [
        Product(product: "Cellebrite (UFDR / Reader report)", support: "Import of report XML (mapper version 1), synthetic fixtures only",
                note: "No specific Cellebrite release is claimed."),
        Product(product: "Microsoft Teams", support: "Import of messages.json exports (fixtures)", note: "Not tested against every tenant export version."),
        Product(product: "i2 Analyst's Notebook", support: "None", note: "No import or export of .anb/.anx. The relationship table (CSV) can be read by tools that read CSV; that is not i2 compatibility."),
        Product(product: "Maltego", support: "None", note: "No transforms, no import or export of Maltego graphs. No parity is claimed."),
        Product(product: "DataWalk", support: "None", note: "No integration. No parity is claimed."),
        Product(product: "Casefleet", support: "None", note: "No integration. Chronology and fact records are this app's own. No parity is claimed."),
        Product(product: "Palantir", support: "None", note: "No integration. No parity is claimed."),
        Product(product: "DEVONthink", support: "Companion bridge (import of a DEVONthink package; Send to DEVONthink)", note: "As described in Help ▸ DEVONthink; not part of the exchange format."),
    ]

    public static func markdown() -> String {
        var out = "<!-- GENERATED from Kalsmritikosh/App/InteropContracts.swift; do not edit by hand. Regenerate: HelpRegistryTests.interopContractsMatch (console) + scripts/help-docs-from-console.py -->\n"
        out += "# Interoperability contracts\n\n"
        out += "What the app exchanges with other products and formats — each adapter's version and field contract, what happens to a missing field or a changed version, the tests that exercise it, and its limits. Anything not listed here is not supported. Passing on a sample is not universal compatibility.\n\n"
        out += "## Adapters\n\n| Adapter | Family | Formats | Tested versions | Fields | Version rule | Tests | Limits |\n|---|---|---|---|---|---|---|---|\n"
        for a in adapters {
            out += "| \(a.name) | \(a.family) | \(a.formats) | \(a.testedVersions) | \(a.fields) | \(a.versionRule) | \(a.tests.joined(separator: ", ")) | \(a.limits) |\n"
        }
        out += "\n## External enrichment connectors\n\n| Connector | Status | Prerequisite |\n|---|---|---|\n"
        for c in connectors { out += "| \(c.name) | \(c.status) | \(c.prerequisite) |\n" }
        out += "\n## Named products\n\n| Product | Support | Note |\n|---|---|---|\n"
        for p in products { out += "| \(p.product) | \(p.support) | \(p.note) |\n" }
        out += "\n"
        return out
    }
}
