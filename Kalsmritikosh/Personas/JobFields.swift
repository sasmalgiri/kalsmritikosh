//
//  JobFields.swift
//  Kalsmritikosh
//
//  Completing the preparation jobs — the contract fields. Each job's contract names the columns its
//  result must carry (a CAPA register: action, owner, due date, linked finding, status; a reliability
//  assessment: rating, rationale…). A shared executor prepares the rows and pre-fills every field the
//  ledger can state (dates, amounts and currencies, content hashes, exhibit and Bates numbers, names,
//  version ids); the person records the judgements in the result screen; completion requires every
//  required field of every accepted row. The fields ARE the contract's required result.
//

import Foundation

public nonisolated struct JobField: Sendable, Hashable, Codable {
    public enum Kind: Sendable, Hashable, Codable { case text, date, choice([String]) }
    public let key: String
    public let label: String
    public let kind: Kind
    public let required: Bool
    /// Where the executor pre-fills it from (nil = the person records it).
    public let prefill: Prefill?
    public enum Prefill: String, Sendable, Hashable, Codable {
        case rowTitle, rowDate, rowDetail, names, document, sourceVersion, contentHash, exhibitNumber, bates,
             amount, currency, firstSentence, constantOpen, methodID
    }
    public init(_ key: String, _ label: String, _ kind: Kind = .text, required: Bool = true, prefill: Prefill? = nil) {
        self.key = key; self.label = label; self.kind = kind; self.required = required; self.prefill = prefill
    }
}

public nonisolated enum JobFields {
    typealias F = JobField

    static let status = F("status", "Status", .choice(["open", "in progress", "done", "reopened"]), prefill: .constantOpen)
    static let hypothesisStatus = F("status", "Status", .choice(["hypothesis", "supported", "refuted", "inconclusive"]))

    static func action(_ what: String, linked: String) -> [F] {
        [F("action", what, prefill: .rowTitle), F("owner", "Owner"), F("due", "Due date", .date),
         F("linked", linked, prefill: .rowDetail), status]
    }
    static let review: [F] = [F("evidence", "Evidence of effect"), F("verdict", "Verdict", .choice(["effective", "not effective"]))]
    static let causal: [F] = [F("link", "Cause or link", prefill: .rowTitle), F("for", "Evidence for"),
                              F("against", "Evidence against", required: false), hypothesisStatus]
    static let interview: [F] = [F("topics", "Topics", prefill: .rowDetail), F("questions", "Questions (each tied to its passage)"),
                                 F("documents", "Documents to put", required: false)]

    /// The contract columns of every job whose result is completed through fields.
    public static let specs: [String: [JobField]] = {
        var m: [String: [JobField]] = [:]
        // Action registers and their effectiveness reviews.
        for j in ["inv.capa-register", "law.remediation", "siu.recovery-actions", "fa.recovery", "hr.corrective-actions",
                  "jrn.correction-actions", "ind.fix-it"] { m[j] = action("Action", linked: "Linked finding") }
        m["gen.to-do"] = action("Research task", linked: "Linked gap")
        m["res.errata"] = [F("item", "Item", prefill: .rowTitle), F("error", "Error"), F("correction", "Correction"), F("date", "Date", .date)]
        m["jrn.correction-history"] = [F("original", "Original", prefill: .rowTitle), F("correction", "Correction"),
                                       F("date", "Date", .date), F("reason", "Reason")]
        for j in JobExecutorKind.reviewedRegister.keys { m[j] = review }
        m["gen.to-do-review"] = [F("result", "Result"), F("effect", "Effect on the conclusion"),
                                 F("verdict", "Verdict", .choice(["effective", "not effective"]))]
        // Inventories, registers, vaults.
        m["jrn.source-vault"] = [F("hash", "SHA-256", prefill: .contentHash), F("protected", "Protected identity", .choice(["no", "yes"])),
                                 F("access", "Access log note")]
        m["siu.prior-claims"] = [F("claim", "Claim"), F("date", "Date", .date, prefill: .rowDate), F("insurer", "Insurer"),
                                 F("amounts", "Amounts", prefill: .amount), F("source", "Source", prefill: .document)]
        m["res.metadata"] = [F("series", "Series"), F("item", "Item metadata", prefill: .rowDetail), F("provenance", "Provenance")]
        m["law.exhibit-binder"] = [F("exhibit", "Exhibit", prefill: .exhibitNumber), F("description", "Description", prefill: .document),
                                   F("version", "Source version", prefill: .sourceVersion), F("bates", "Bates", prefill: .bates)]
        m["law.document-coding"] = [F("issues", "Issue codes"), F("relevance", "Relevance", .choice(["relevant", "not relevant", "needs review"])),
                                    F("privilege", "Privilege", .choice(["none", "privileged", "partly privileged"]))]
        m["res.bibliography"] = [F("author", "Author", prefill: .names), F("title", "Title", prefill: .document),
                                 F("date", "Date", .date, prefill: .rowDate), F("absent", "Cited but absent", .choice(["no", "yes"]))]
        m["res.edition"] = [F("text", "Source text", prefill: .firstSentence), F("annotation", "Annotation"),
                            F("apparatus", "Apparatus", required: false), F("lineage", "Lineage (version)", prefill: .sourceVersion)]
        m["gen.originals"] = [F("citation", "Citation", prefill: .rowTitle), F("repository", "Repository"), F("hash", "Image / file hash", prefill: .contentHash)]
        m["ind.document-versions"] = [F("document", "Document", prefill: .document), F("versionDate", "Version date", .date, prefill: .rowDate),
                                      F("current", "Current", .choice(["yes", "no"])), F("expiry", "Expiry", .date, required: false)]
        m["ind.property"] = [F("asset", "Asset"), F("document", "Document", prefill: .document), F("date", "Date", .date, prefill: .rowDate), F("status", "Status")]
        m["ind.insurance"] = [F("policy", "Policy"), F("insurer", "Insurer"), F("cover", "Cover"),
                              F("renewal", "Renewal", .date, prefill: .rowDate), F("document", "Document", prefill: .document)]
        m["ind.applications"] = [F("application", "Application or dispute"), F("submitted", "Submitted", .date, prefill: .rowDate),
                                 F("status", "Status"), F("document", "Document", prefill: .document)]
        m["ind.document-vault"] = [F("original", "Original", prefill: .document), F("hash", "SHA-256", prefill: .contentHash),
                                   F("location", "Location"), F("access", "Access")]
        // Assessments.
        m["inv.source-reliability"] = [F("reliability", "Source reliability (Admiralty)", .choice(["A", "B", "C", "D", "E", "F"])),
                                       F("credibility", "Information credibility", .choice(["1", "2", "3", "4", "5", "6"])), F("rationale", "Rationale")]
        m["res.source-criticism"] = [F("origin", "Origin"), F("authorship", "Authorship"), F("bias", "Bias"), F("reliability", "Reliability and reasons")]
        m["jrn.source-map"] = [F("relationship", "Relationship"), F("family", "Independence family"),
                               F("protection", "Protection", .choice(["none", "confidential source"]))]
        let factor: JobField.Kind = .choice(["supports", "neutral", "undermines"])
        m["hr.credibility"] = [F("consistency", "Consistency", factor), F("corroboration", "Corroboration", factor),
                               F("plausibility", "Plausibility", factor), F("reasons", "Reasons")]
        m["gen.source-analysis"] = [F("source", "Source", .choice(["original", "derivative", "authored"])),
                                    F("information", "Information", .choice(["primary", "secondary", "indeterminate"])),
                                    F("evidence", "Evidence", .choice(["direct", "indirect", "negative"]))]
        // Matrices and worksheets.
        m["law.parties-issues"] = [F("kind", "Party or issue", .choice(["party", "issue"])), F("entity", "Linked entity", prefill: .names),
                                   F("claim", "Claim", required: false)]
        m["law.fact-evidence"] = [F("element", "Element"), F("stance", "Evidence", .choice(["supports", "contradicts"]))]
        m["law.obligations"] = [F("clause", "Clause", prefill: .rowTitle), F("party", "Party"), F("trigger", "Trigger"),
                                F("status", "Status", .choice(["open", "performed", "breached", "disputed"]))]
        m["siu.red-flags"] = [F("indicator", "Indicator"), F("innocent", "Innocent explanation"), F("response", "Response")]
        m["hr.allegations"] = [F("allegation", "Allegation"), F("response", "Response"),
                               F("stance", "Evidence", .choice(["supports", "contradicts", "neutral"]))]
        // Statements and interviews.
        m["res.transcription"] = [F("original", "Original", prefill: .rowTitle), F("transcription", "Transcription"),
                                  F("translation", "Translation", required: false), F("codes", "Codes")]
        m["jrn.transcript"] = [F("speaker", "Speaker (corrected)", prefill: .names), F("timecode", "Timecode", required: false),
                               F("correction", "Correction log", required: false)]
        m["hr.statements"] = [F("point", "Point"), F("witness", "Witness", prefill: .names),
                              F("comparison", "Comparison", .choice(["agrees", "differs", "silent"]))]
        m["jrn.interview-plan"] = [F("claims", "Claims to put"), F("questions", "Questions"),
                                   F("status", "Status", .choice(["planned", "asked", "answered", "no response"]))]
        m["law.witness-profiles"] = [F("statements", "Statements", prefill: .rowDetail), F("documents", "Documents authored or received"),
                                     F("inconsistencies", "Inconsistencies")]
        m["law.deposition"] = [F("topic", "Topic", prefill: .rowDetail), F("questions", "Questions (each tied to its passage)"),
                               F("disputed", "Disputed points", required: false), F("exhibits", "Exhibits", required: false)]
        m["siu.euo-prep"] = interview
        m["hr.interview-prep"] = interview + [F("opportunity", "Response opportunity", .choice(["given", "not yet"]))]
        // Causation and hypotheses.
        for j in ["res.causal", "law.causation", "jrn.causal", "ind.why", "siu.causation"] { m[j] = causal }
        m["fa.analysis"] = [F("hypothesis", "Hypothesis", prefill: .rowTitle), F("for", "Evidence for"),
                            F("against", "Evidence against", required: false), hypothesisStatus]
        m["gen.migration"] = m["fa.analysis"]
        m["res.alternative"] = [F("account", "Account"), F("for", "Supporting evidence"), F("against", "Contrary evidence")]
        // Money.
        m["law.damages"] = [F("head", "Head of damage"), F("amount", "Amount", prefill: .amount),
                            F("currency", "Currency", prefill: .currency), F("source", "Source", prefill: .document), F("assumptions", "Assumptions")]
        m["fa.funds-tracing"] = [F("from", "From account"), F("to", "To account"), F("date", "Date", .date),
                                 F("amount", "Amount", prefill: .amount), F("currency", "Currency", prefill: .currency),
                                 F("method", "Tracing method", .choice(["direct", "LIBR", "pro rata", "FIFO"]))]
        m["fa.workpapers"] = [F("calculation", "Calculation"), F("inputs", "Inputs", prefill: .amount)]
        // Disclosure.
        m["ind.health-scope"] = [F("record", "Record", prefill: .document), F("sensitivity", "Sensitivity", .choice(["ordinary", "sensitive", "highly sensitive"])),
                                 F("permission", "Sharing permission", .choice(["may share", "do not share"]))]
        m["ind.secure-share"] = [F("include", "Include", .choice(["include", "withhold"])), F("redactions", "Redactions", required: false),
                                 F("recipient", "Recipient")]
        m["hr.disclosure-review"] = [F("endorsement", "Endorsement or testimonial", .choice(["yes", "no"])),
                                     F("connection", "Material connection"), F("required", "Required disclosure"),
                                     F("present", "Disclosure", .choice(["present", "absent", "unclear"])),
                                     F("instrument", "Instrument (e.g. FTC Endorsement Guides, 16 CFR 255)"), F("version", "Instrument version")]
        // Publication, deadlines, identity, chronology variants, methods.
        m["jrn.publication"] = [F("cleared", "Claim cleared", .choice(["cleared", "held"])), F("conditions", "Conditions", required: false)]
        m["jrn.publication-package"] = [F("cleared", "Claim cleared", .choice(["cleared", "held"])), F("finalText", "Final text")]
        m["law.deadlines"] = [F("trigger", "Trigger", prefill: .rowTitle), F("rule", "Rule or source"), F("computed", "Computed date", .date, prefill: .rowDate)]
        m["gen.same-person"] = [F("identifiers", "Identifiers compared"), F("conflicts", "Conflicts", required: false),
                                F("conclusion", "Conclusion", .choice(["same person", "different people", "undecided"]))]
        m["inv.linkage"] = [F("entities", "Linked entities", prefill: .names), F("edge", "Link (who–what)", required: false)]
        m["res.chronology"] = [F("period", "Period")]
        m["gen.family-lines"] = [F("person", "Person", prefill: .names), F("relationship", "Relationship"), F("relative", "Related person")]
        for j in ["inv.methods", "res.methods", "jrn.methods", "ind.methods", "law.methods", "fa.methods", "gen.methods"] {
            m[j] = [F("method", "Method", prefill: .methodID), F("inputs", "Inputs selected"), F("steps", "Steps taken"),
                    F("outcome", "Outcome", .choice(["supports", "contradicts", "inconclusive"]))]
        }
        return m
    }()

    /// Pre-fill every field the ledger can state; never overwrite a value already set.
    static func prefill(job: String, rows: [JobResultRow], evidence: JobEvidence?) -> [JobResultRow] {
        guard let spec = specs[job] else { return rows }
        let docs = evidence?.facts.documents ?? []
        return rows.enumerated().map { i, row in
            var r = row
            var fields = r.fields ?? [:]
            let doc = row.refs.compactMap { ref in docs.first { $0.objectID == ref.objectID || ($0.sourceVersionID != nil && $0.sourceVersionID == ref.sourceVersionID) } }.first
            for f in spec where (fields[f.key] ?? "").isEmpty {
                let value: String?
                switch f.prefill {
                case .rowTitle?: value = row.title
                case .rowDate?: value = row.date
                case .rowDetail?: value = row.detail
                case .names?: value = row.detail.map { $0.replacingOccurrences(of: "Names: ", with: "") }
                case .document?: value = doc?.name ?? row.title
                case .sourceVersion?: value = (row.refs.first?.sourceVersionID ?? doc?.sourceVersionID)?.uuidString
                case .contentHash?: value = (row.refs.first?.sourceVersionID ?? doc?.sourceVersionID).flatMap { evidence?.versionHashes[$0] }
                case .exhibitNumber?: value = String(format: "EX-%03d", i + 1)
                case .bates?: value = String(format: "%@-%06d", evidence?.batesPrefix ?? "PROD", i + 1)
                case .amount?: value = FAMoney.value(of: row.title).map(FAMoney.format) ?? (row.title.rangeOfCharacter(from: .decimalDigits) != nil ? row.title : nil)
                case .currency?: value = { let c = FAMoney.currency(of: row.title); return c.isEmpty ? nil : c }()
                case .firstSentence?: value = row.refs.first?.quote
                case .constantOpen?: value = "open"
                case .methodID?: value = row.fields?["methodID"] ?? row.title
                case nil: value = nil
                }
                if let v = value, !v.isEmpty { fields[f.key] = v }
            }
            r.fields = fields
            return r
        }
    }

    /// The required fields an accepted row still lacks (empty when complete).
    public static func missing(job: String, row: JobResultRow) -> [JobField] {
        guard row.decision == .accepted, let spec = specs[job] else { return [] }
        return spec.filter { f in
            guard f.required else { return false }
            let v = (row.fields?[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { return true }
            if case .choice(let options) = f.kind { return !options.contains(v) }
            return false
        }
    }
}

// MARK: - Executors that complete by computation

/// `inv.data-lab`, `jrn.data-desk` — a reproducible, source-linked analysis of the case's structured
/// values: counts per field, distinct values, and totals per stated currency (never across
/// currencies), each result row citing the rows it was computed from. The query is recorded so the
/// same analysis re-runs to the same result over the same sources.
public nonisolated enum DataAnalysisExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        let table = DataTableExecutor.run(e)
        guard table.state != .blocked else { return table }
        var byLabel: [String: [JobResultRow]] = [:]
        for r in table.content.rows {
            let label = r.title.components(separatedBy: " = ").first ?? r.title
            byLabel[label, default: []].append(r)
        }
        var rows: [JobResultRow] = []
        for (label, group) in byLabel.sorted(by: { $0.key < $1.key }) {
            let values = Set(group.map { $0.title.components(separatedBy: " = ").dropFirst().joined(separator: " = ") })
            var detail = "\(group.count) value(s), \(values.count) distinct"
            if label == "amount" {
                var totals: [String: Decimal] = [:]
                var left = 0
                for g in group {
                    let v = g.title.components(separatedBy: " = ").dropFirst().joined()
                    let c = FAMoney.currency(of: v)
                    if let d = FAMoney.value(of: v), !c.isEmpty { totals[c, default: 0] += d } else { left += 1 }
                }
                detail += "; totals: " + (totals.isEmpty ? "none (no amount with a stated currency)" : totals.sorted { $0.key < $1.key }.map { "\($0.key) \(FAMoney.format($0.value))" }.joined(separator: ", "))
                if left > 0 { detail += "; \(left) amount(s) not totalled (no currency or not one figure)" }
            }
            rows.append(JobResultRow(title: "\(label): \(values.sorted().prefix(5).joined(separator: ", "))\(values.count > 5 ? " …" : "")",
                                     detail: detail, refs: Array(group.flatMap(\.refs).prefix(8))))
        }
        let query = "group the case's structured values by field; count values and distinct values; total amounts per stated currency"
        return (.draft, JobResultContent(rows: rows, limitations: table.content.limitations + ["Query: \(query). Re-running over the same sources gives the same result."],
                                         nextActions: ["Review each computed row against its sources; record your interpretation in the row note."]))
    }
}

/// `law.redaction` — validation of PRODUCED bytes: every export recorded for the case (the exact
/// snapshot that was written) is re-read for the identifiers the case's documents contain, through
/// every leak channel (exact, case, collapsed spacing, markup or punctuation interruption).
public nonisolated enum RedactionValidationExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        guard !e.exports.isEmpty else {
            return JobText.blocked("No produced export is recorded for this case, so there is nothing to validate.",
                                   "Produce the set (Document production or a studio export), then run this job.")
        }
        var terms: [String] = []
        for doc in e.facts.documents {
            let text = e.texts[doc.objectID] ?? ""
            for (_, pattern) in DisclosureExecutor.patterns.dropLast() {   // identifiers, not health terms
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let ns = text as NSString
                terms += re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
            }
        }
        terms = Array(Set(terms)).sorted()
        let verifier = RedactionVerifier()
        let rows = e.exports.map { export -> JobResultRow in
            let leaks = verifier.leaks(in: export.text, protectedTerms: terms, artifact: export.title)
            let channels = Set(leaks.map(\.channel.rawValue)).sorted()
            return JobResultRow(title: export.title,
                                detail: leaks.isEmpty ? "Clean: none of \(terms.count) identifier(s) recoverable from the produced text."
                                                      : "\(leaks.count) identifier(s) recoverable (\(channels.joined(separator: ", "))).",
                                flags: leaks.isEmpty ? ["text check passed"] : ["redaction failed"])
        }
        return (.draft, JobResultContent(rows: rows,
                                         limitations: ["Checked: the produced text of each export. Image OCR and file metadata are checked by the production tool when it writes PDFs; a text snapshot has neither."],
                                         nextActions: ["Re-produce any export that failed, then run this job again."]))
    }
}
