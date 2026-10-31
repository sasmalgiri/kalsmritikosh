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
    /// B2 — `.date` is a real calendar day (yyyy-mm-dd), `.amount` one exact amount, `.currency` an
    /// ISO 4217 code; a nonempty value that does not parse does not complete the field.
    public enum Kind: Sendable, Hashable, Codable { case text, date, choice([String]), amount, currency }
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
                                 // The protected source's name(s), “;”-separated: kept out of every export and masked in every
                                 // cloud send of this ledger (`ProtectedIdentities`). Required once protected = yes (completion rule).
                                 F("identity", "Protected identity's name (kept out of exports and AI payloads)", required: false),
                                 F("access", "Access log note")]
        m["siu.prior-claims"] = [F("claim", "Claim"), F("date", "Date", .date, prefill: .rowDate), F("insurer", "Insurer"),
                                 F("amounts", "Amounts", prefill: .amount), F("source", "Source", prefill: .document)]
        m["res.metadata"] = [F("series", "Series"), F("item", "Item metadata", prefill: .rowDetail), F("provenance", "Provenance")]
        m["law.exhibit-binder"] = [F("exhibit", "Exhibit", prefill: .exhibitNumber), F("description", "Description", prefill: .document),
                                   F("version", "Source version", prefill: .sourceVersion),
                                   // B3 — numbered from document order: a PROPOSAL. Production assigns the final
                                   // numbers (the ledger records ranges per run, not per document).
                                   F("bates", "Bates (proposed — production assigns the final number)", prefill: .bates)]
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
        m["jrn.source-map"] = [F("relationship", "Relationship"), F("family", "Text-similarity candidates (the app's reading)"),
                               F("lineage", "Confirmed lineage (your decision, rationale in the note)",
                                 .choice(["independent", "same origin (wire, syndication)", "derivative (rewrite)", "unknown"]), required: false),
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
                                  F("translation", "Translation (beside its transcription — never instead of it)", required: false), F("codes", "Codes"),
                                  F("lineage", "Lineage (original → transcription → translation)", prefill: .sourceVersion)]
        m["jrn.transcript"] = [F("speaker", "Speaker (corrected)", prefill: .names), F("timecode", "Timecode", required: false),
                               F("correction", "Correction log", required: false)]
        m["hr.statements"] = [F("point", "Point"), F("witness", "Witness", prefill: .names),
                              F("comparison", "Comparison", .choice(["agrees", "differs", "silent"])),
                              F("event", "Event (correct it if these statements describe different events)", required: false)]
        m["jrn.interview-plan"] = [F("claims", "Claims to put"), F("questions", "Questions"),
                                   F("status", "Status", .choice(["planned", "asked", "answered", "no response"]))]
        m["law.witness-profiles"] = [F("statements", "Statements", prefill: .rowDetail), F("documents", "Documents authored or received"),
                                     F("inconsistencies", "Inconsistencies")]
        m["law.deposition"] = [F("topic", "Topic", prefill: .rowDetail), F("questions", "Question (tied to its cited passage)", prefill: .rowTitle),
                               F("disputed", "Disputed points", required: false), F("exhibits", "Exhibits", required: false)]
        m["siu.euo-prep"] = [F("topics", "Topic", prefill: .rowDetail), F("questions", "Question (tied to its cited passage)", prefill: .rowTitle),
                             F("documents", "Documents to put", required: false, prefill: .document)]
        m["hr.interview-prep"] = interview + [F("opportunity", "Response opportunity", .choice(["given", "not yet"]))]
        // Causation and hypotheses.
        for j in ["res.causal", "law.causation", "jrn.causal", "ind.why", "siu.causation"] { m[j] = causal }
        m["fa.analysis"] = [F("hypothesis", "Hypothesis", prefill: .rowTitle), F("for", "Evidence for"),
                            F("against", "Evidence against", required: false), hypothesisStatus]
        m["gen.migration"] = m["fa.analysis"]
        m["res.alternative"] = [F("account", "Account"), F("for", "Supporting evidence"), F("against", "Contrary evidence")]
        // Money.
        m["law.damages"] = [F("head", "Head of damage"), F("amount", "Amount", .amount, prefill: .amount),
                            F("currency", "Currency", .currency, prefill: .currency), F("source", "Source", prefill: .document), F("assumptions", "Assumptions")]
        // B3 — a sourced MANUAL tracing workpaper: the person links the two accounts, classifies the
        // transfer, says how duplicates and reversals were handled and whether it reconciles, and states
        // the method they applied. The app does not compute LIBR/FIFO/pro-rata allocations.
        m["fa.funds-tracing"] = [F("from", "From account"), F("to", "To account"), F("date", "Date", .date),
                                 F("amount", "Amount", .amount, prefill: .amount), F("currency", "Currency", .currency, prefill: .currency),
                                 F("classification", "Classification", .choice(["transfer", "payment", "receipt", "fee", "unknown"])),
                                 F("duplicates", "Duplicates and reversals", .choice(["none found", "duplicate excluded", "reversal netted", "kept separate — distinct payment"])),
                                 F("reconciled", "Reconciles to", .choice(["statement balance", "other workpaper", "does not reconcile"])),
                                 F("method", "Tracing method (applied by you)", .choice(["direct", "LIBR", "pro rata", "FIFO"]))]
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
        m["res.chronology"] = [F("period", "Period"), F("dated", "Dated (precision or range, from the document)", required: false)]
        m["gen.family-lines"] = [F("person", "Person", prefill: .names), F("relationship", "Relationship"),
                                 F("relative", "Related person (empty for a vital event)", required: false)]
        // inv.data-lab — the person's analysis definition, recorded on the "Analysis" row and applied on the next run.
        m["inv.data-lab"] = [F("filter", "Filter (label = value · label contains text · document = name)", required: false),
                             F("groupBy", "Group by (label · document)", required: false),
                             F("total", "Total (the label whose amounts are summed per currency)", required: false)]
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
                case .amount?: value = FAMoney.value(of: row.title).map(FAMoney.format)
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
            let v = (row.fields?[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { return f.required }
            // A value given (required or optional) must be a valid value of its kind.
            return invalidReason(f.kind, v) != nil
        }
    }

    /// B3 — the job's own completion rules across fields and rows (empty when the result may be
    /// completed). Negative outcomes are valid; what is refused is a completion that contradicts the
    /// contract's acceptance scenario.
    public static func completionProblems(job: String, rows: [JobResultRow]) -> [String] {
        let accepted = rows.filter { $0.decision == .accepted }
        var out: [String] = []
        func note(_ r: JobResultRow) -> Bool { !(r.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // An item that must rest on a source cannot be accepted without one (a hand-added row is
        // the reviewer's entry until a source is linked).
        if ["hr.evidence-register", "siu.prior-claims", "law.obligations", "law.exhibit-binder"].contains(job),
           accepted.contains(where: { $0.refs.isEmpty }) {
            out.append("An item without a source cannot be accepted here: link its source, or reject it")
        }
        switch job {
        case "law.redaction":
            if accepted.contains(where: { $0.fields?["check"] != "produced file" }) {
                out.append("A text-only snapshot check cannot complete redaction validation: check the produced file itself, or reject the snapshot row")
            }
            if accepted.contains(where: { $0.fields?["check"] == "produced file" && $0.fields?["outcome"] != "passed" }) {
                out.append("A failed or incomplete file check cannot be accepted: re-produce the file and check it again, or reject the row")
            }
            if !rows.contains(where: { $0.fields?["check"] == "produced file" }) {
                out.append("No produced file has been checked")
            }
        case "hr.interview-prep":
            if accepted.contains(where: { $0.fields?["opportunity"] == "not yet" }) {
                out.append("Every allegation must be put to the respondent before completion (Response opportunity: given)")
            }
        case "jrn.publication", "jrn.publication-package":
            let cleared = accepted.contains { $0.fields?["cleared"] == "cleared" }
            let openReplies = rows.filter { $0.title.hasPrefix("Reply opportunity") && $0.decision != .accepted }
            if cleared && !openReplies.isEmpty {
                out.append("Publication cannot be cleared while \(openReplies.count) reply request(s) are not made (accept each Reply opportunity row once requested)")
            }
        case "fa.funds-tracing":
            if accepted.contains(where: { ($0.fields?["from"] ?? "") == ($0.fields?["to"] ?? "") && !($0.fields?["from"] ?? "").isEmpty }) {
                out.append("A transfer links two different accounts")
            }
        case "hr.disclosure-review":
            if accepted.contains(where: { $0.fields?["endorsement"] == "yes" && $0.fields?["present"] != "present" && !note($0) }) {
                out.append("An endorsement without a clear disclosure needs your note on what must change (it is flagged against the instrument version)")
            }
        // Release-block directive item 1 — each reopened job's own scenario rule.
        case "law.deposition", "siu.euo-prep":
            if accepted.contains(where: { $0.refs.isEmpty }) {
                out.append("Each question links to a document passage: link the source of every accepted question, or reject it")
            }
        case "hr.statements":
            if accepted.contains(where: { ($0.fields?["witness"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) {
                out.append("A statement whose speaker is unassigned cannot be accepted: name the witness from the source, or reject the row")
            }
        case "jrn.source-map":
            if accepted.contains(where: { !($0.fields?["lineage"] ?? "").isEmpty && $0.fields?["lineage"] != "unknown" && !note($0) }) {
                out.append("A lineage decision (independent, same origin, derivative) needs its rationale in the note — the app's text reading is not a reason")
            }
        case "fa.workpapers":
            if accepted.contains(where: { $0.flags.contains(WorkpaperExecutor.untraced) }) {
                out.append("A report figure that traces to no workpaper cannot be accepted: add the workpaper with its source, or reject the figure")
            }
        case "res.transcription":
            if accepted.contains(where: { !($0.fields?["translation"] ?? "").isEmpty && ($0.fields?["transcription"] ?? "").isEmpty }) {
                out.append("A translation needs the transcription it was made from (Transcription), so the lineage original → transcription → translation is kept")
            }
            if accepted.contains(where: { !($0.fields?["translation"] ?? "").isEmpty && $0.refs.isEmpty }) {
                out.append("A translation must link to its original passage: link the source, or reject the row")
            }
        case "jrn.source-vault":
            if accepted.contains(where: { $0.fields?["protected"] == "yes" && ProtectedIdentities.names(in: [$0]).isEmpty }) {
                out.append("A protected source needs its identity recorded (Protected identity's name) so it is kept out of exports and AI payloads")
            }
        case "res.edition":
            if accepted.contains(where: { !($0.fields?["annotation"] ?? "").isEmpty && $0.refs.isEmpty }) {
                out.append("An annotation must link to its source passage: link the passage, or reject the row")
            }
        case "law.document-coding":
            if accepted.contains(where: { DocumentCodingProduction.withholdingCodes.contains($0.fields?["privilege"] ?? "") && $0.refs.isEmpty }) {
                out.append("A privilege code withholds a document from production, so the row must cite the document it codes")
            }
        default:
            // Action registers: an action marked done needs its closure note.
            if JobFields.specs[job]?.contains(where: { $0.key == "status" && $0.label == "Status" && $0.prefill == .constantOpen }) == true,
               accepted.contains(where: { $0.fields?["status"] == "done" && !note($0) }) {
                out.append("An action marked done needs a closure note")
            }
        }
        return out
    }

    /// Why a nonempty value is not a valid value of its kind (nil: valid).
    public static func invalidReason(_ kind: JobField.Kind, _ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text: return nil
        case .choice(let options): return options.contains(v) ? nil : "not one of the listed choices"
        case .date: return isoDay(v) == nil ? "not a calendar date (yyyy-mm-dd)" : nil
        case .amount: return FAMoney.value(of: v) == nil ? "not one exact amount (e.g. 1,250.00)" : nil
        case .currency: return Self.currencyCodes.contains(v.uppercased()) && v.count == 3 ? nil : "not an ISO currency code (e.g. USD)"
        }
    }

    /// "2026-02-30" is not a day; only a date that round-trips is.
    public static func isoDay(_ s: String) -> Date? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d ? date : nil
    }

    static let currencyCodes: Set<String> = Set(Locale.Currency.isoCurrencies.map { $0.identifier.uppercased() })
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

/// `law.redaction` — validation of PRODUCED files (B3). The result the contract needs is a check of
/// the actual file: the person chooses each produced file, its bytes are hashed and every channel it
/// carries is checked (`ProducedFileRedactionCheck`: PDF text layer, metadata, annotations, OCR of
/// image pages; attachments reported). A run over the case's recorded export snapshots is a
/// TEXT-ONLY pre-check, labelled so, and cannot complete the job.
public nonisolated enum RedactionValidationExecutor {
    /// The identifiers the case's own documents contain — what a produced file must not reveal.
    public static func protectedTerms(_ e: JobEvidence) -> [String] {
        var terms: [String] = []
        for doc in e.facts.documents {
            let text = e.texts[doc.objectID] ?? ""
            for (_, pattern) in DisclosureExecutor.patterns.dropLast() {   // identifiers, not health terms
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let ns = text as NSString
                terms += re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
            }
        }
        return Array(Set(terms)).sorted()
    }

    public static func run(_ e: JobEvidence) -> JobRun {
        guard !e.facts.documents.isEmpty else {
            return JobText.blocked("The case has no documents, so there are no protected identifiers to check a production for.",
                                   "Add the case's documents, then check the produced files.")
        }
        let terms = protectedTerms(e)
        let verifier = RedactionVerifier()
        let rows = e.exports.map { export -> JobResultRow in
            let leaks = verifier.leaks(in: export.text, protectedTerms: terms, artifact: export.title)
            let channels = Set(leaks.map(\.channel.rawValue)).sorted()
            return JobResultRow(title: export.title,
                                detail: leaks.isEmpty ? "Text-only pre-check: none of \(terms.count) identifier(s) in the recorded snapshot text."
                                                      : "\(leaks.count) identifier(s) recoverable from the snapshot text (\(channels.joined(separator: ", "))).",
                                flags: [leaks.isEmpty ? "text-only pre-check passed — not a check of the file" : "redaction failed"],
                                fields: ["check": "text-only snapshot"])
        }
        return (.draft, JobResultContent(rows: rows,
                                         limitations: ["The produced FILES are not checked yet: choose each one with “Check a produced file…”. A snapshot row checks only the recorded text (no PDF text layer, OCR, metadata or attachments) and cannot complete this job."]
                                            + (rows.isEmpty ? ["No export snapshot is recorded for this case; check the produced files directly."] : []),
                                         nextActions: ["Check each produced file; re-produce any that fails, then check it again."]))
    }

    /// One row per checked file: its identity (name, SHA-256), what was checked and what was not.
    public static func row(for c: ProducedFileRedactionCheck, terms: Int) -> JobResultRow {
        var flags: [String] = []
        if !c.leaks.isEmpty { flags.append("redaction failed") }
        if !c.notChecked.isEmpty { flags.append("incomplete check") }
        if c.passed { flags.append("file check passed") }
        let detail = (c.leaks.isEmpty ? "No protected identifier (of \(terms)) found" : "\(c.leaks.count) leak(s): \(c.leaks.joined(separator: "; "))")
            + ". Checked: \(c.checked.joined(separator: ", "))." + (c.notChecked.isEmpty ? "" : " Not checked: \(c.notChecked.joined(separator: "; ")).")
        return JobResultRow(title: c.fileName, detail: detail, flags: flags,
                            fields: ["check": "produced file", "sha256": c.sha256, "coverage": c.checked.joined(separator: ", "),
                                     "notChecked": c.notChecked.joined(separator: "; "), "outcome": c.passed ? "passed" : (c.leaks.isEmpty ? "incomplete" : "failed")])
    }
}
