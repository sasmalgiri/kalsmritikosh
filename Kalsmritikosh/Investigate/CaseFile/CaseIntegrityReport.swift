//
//  CaseIntegrityReport.swift
//  Kalsmritikosh
//
//  ALCOA ALC-13 (DATA-23, owner 2026-11-24) — traceable. The per-case "Data integrity report" (Case tools ▸ Data
//  integrity report): a plain-English summary first, then — for each of the twelve principles (ALCOA++ with Secure and
//  Reliable) — what the app recorded for this case: the audit-chain check (with rows erased by a recorded erasure),
//  custody per document, a re-hash of each kept original, AI runs (model asked for and served, prompt version, request
//  SHA-256), AI findings with the person's decisions, refused AI writes, the outbound log for the case, revisions with
//  their reasons, the access log, clock jumps and time zones, coverage (what was not read and why), legal holds and
//  erasures, backups and the last practice restore, the retention register, key rotations and export certifications.
//  Exported as an archival PDF, a machine-readable JSON and the evidence files' manifest (CSV), each with its
//  certification, optionally inside one password-protected ZIP.
//
//  Wording rule: "built on ALCOA++ principles, with Secure and Reliable" — never "compliant". The report states what was
//  recorded; it does not certify the case.
//

import Foundation
import os

public nonisolated struct CaseIntegrityReport: Codable, Sendable, Equatable {

    public static let wording = "Built on ALCOA++ principles, with Secure and Reliable. This report states what the app recorded for this case; it is not a validation, an e-signature or a statement of compliance."
    public static let principleNames = ["Attributable", "Legible", "Contemporaneous", "Original", "Accurate", "Complete", "Consistent",
                                        "Enduring", "Available", "Traceable", "Secure", "Reliable"]

    public struct Principle: Codable, Sendable, Equatable { public let name: String; public let lines: [String] }
    public struct Document: Codable, Sendable, Equatable {
        public let fileID: String
        public let name: String
        public let sourceVersion: String?
        public let sha256AtIntake: String?
        public let vaultAddress: String?
        public let vaultCheck: String
        public let custody: [String: Int]
    }
    public struct AIRun: Codable, Sendable, Equatable {
        public let id: String, kind: String, provider: String, modelRequested: String, modelServed: String?
        public let promptVersion: String?, requestedBy: String, state: String, startedAt: String, zone: String?
    }
    public struct AIFinding: Codable, Sendable, Equatable {
        public let id: String, kind: String, text: String, runID: String?, modelRequested: String?, modelServed: String?
        public let requestSHA256: String?, promptVersion: String?, decision: String?, approver: String?, reason: String?
    }
    public struct Revision: Codable, Sendable, Equatable { public let recordKind: String, change: String, actor: String, reason: String?, at: String }
    public struct Access: Codable, Sendable, Equatable { public let kind: String, actor: String, at: String, zone: String }
    public struct NotRead: Codable, Sendable, Equatable { public let document: String, why: String }

    public let caseID: String
    public let caseTitle: String
    public let generatedAt: String
    public let generatedBy: String
    public let zone: String
    public let statement: String
    public var summary: [String]
    public var principles: [Principle]
    public let chainStatus: String
    public let chainIntact: Bool?
    public let chainErasedRecorded: Int
    public let documents: [Document]
    public let aiRuns: [AIRun]
    public let aiFindings: [AIFinding]
    public let refusedWrites: Int
    public let aiExchanges: Int
    public let outbound: [String: Int]
    public let revisions: [Revision]
    public let access: [Access]
    public let clockJumps: Int
    public let zones: [String]
    public let notRead: [NotRead]
    public let holds: [String]
    public let erasures: [String]
    public let practiceRestore: String
    public let retention: [String: String]
    public let keyRotations: [String]
    public let certifications: Int
    public let retractedTranscripts: Int
    public let ledgerEncrypted: Bool

    // MARK: - Build

    /// What the app holds outside the ledger, handed in by the caller.
    public struct Inputs: Sendable {
        public var chain: AuditChainVerification?
        public var chainError: String?
        public var vault: EvidenceVault?
        public var ledgerURL: URL?
        public var ledgerEncrypted: Bool
        public var actor: String
        public init(chain: AuditChainVerification?, chainError: String? = nil, vault: EvidenceVault?, ledgerURL: URL?, ledgerEncrypted: Bool, actor: String) {
            self.chain = chain; self.chainError = chainError; self.vault = vault; self.ledgerURL = ledgerURL
            self.ledgerEncrypted = ledgerEncrypted; self.actor = actor
        }
    }

    static func iso(_ d: Date?) -> String {
        guard let d else { return "" }
        return ISO8601DateFormatter.string(from: d, timeZone: .current, formatOptions: [.withInternetDateTime])
    }

    static func has(_ db: Database, _ table: String) async -> Bool {
        do { return !(try await db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;", [.text(table)]).isEmpty) } catch {
            KalsmritikoshLog.storage.error("Integrity report: schema not read: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    public static func build(_ db: Database, caseID: UUID, inputs: Inputs, now: Date = Date()) async throws -> CaseIntegrityReport {
        try await CaseAccessPolicy.requireRead(db, caseID: caseID)
        let cid = SQLValue.uuid(caseID)
        let title = try await db.query("SELECT title FROM investigation_cases WHERE id = ?;", [cid]).first?.string(0) ?? "Case"
        let files = try await db.query("SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1;", [cid]).compactMap { $0.string(0) }

        // Documents: the current version, its intake SHA-256, the vault re-hash and the custody counts.
        var documents: [Document] = []
        // A case source names a source version (or, in older rows, the logical source); the document is the logical source.
        for ref in files.prefix(2_000) {
            let v = try await db.query("""
                SELECT id, filename, content_hash, vault_address, logical_source_id FROM source_versions
                WHERE upper(id) = upper(?) OR (upper(logical_source_id) = upper(?) AND is_current = 1) ORDER BY is_current DESC LIMIT 1;
                """, [.text(ref), .text(ref)]).first
            let file = v?.string(4) ?? ref
            var custody: [String: Int] = [:]
            for r in try await db.query("SELECT kind, COUNT(*) FROM custody_events WHERE upper(file_id) = upper(?) GROUP BY kind;", [.text(file)]) {
                if let k = r.string(0) { custody[k] = Int(r.int(1) ?? 0) }
            }
            var check = "not kept in the vault (reference mode)"
            if let addr = v?.string(3), !addr.isEmpty, let vault = inputs.vault {
                let c = await vault.checkedData(for: addr).check
                switch c {
                case .verified: check = "re-hashed now: matches"
                case .mismatch: check = "re-hashed now: DOES NOT MATCH"
                case .notVaulted: check = "vault copy missing"
                case .notOpenable: check = "vault copy could not be opened"
                }
            }
            documents.append(Document(fileID: file, name: v?.string(1) ?? file, sourceVersion: v?.string(0), sha256AtIntake: v?.string(2),
                                      vaultAddress: v?.string(3), vaultCheck: check, custody: custody))
        }

        // AI runs, findings with decisions, refused writes, kept exchanges.
        let runs: [AIRun] = try await db.query("""
            SELECT id, task_kind, provider, model, answered_by_model, prompt_version, requested_by, state, started_at, recorded_tz
            FROM case_ai_runs WHERE case_id = ? ORDER BY started_at;
            """, [cid]).map { r in
            AIRun(id: r.string(0) ?? "", kind: r.string(1) ?? "", provider: r.string(2) ?? "", modelRequested: r.string(3) ?? "",
                  modelServed: r.string(4), promptVersion: r.string(5), requestedBy: r.string(6) ?? "", state: r.string(7) ?? "",
                  startedAt: iso(r.date(8)), zone: r.string(9))
        }
        let latest = try await CaseAIRecordRepository(database: db).latestDecisions(caseID: caseID)
        let findings: [AIFinding] = try await db.query("""
            SELECT id, kind, text, run_id, model_requested, model_served, request_sha256, prompt_version FROM case_ai_records
            WHERE case_id = ? AND withdrawn_at IS NULL ORDER BY created_at;
            """, [cid]).map { r in
            let d = r.uuid(0).flatMap { latest[$0] }
            return AIFinding(id: r.string(0) ?? "", kind: r.string(1) ?? "", text: r.string(2) ?? "", runID: r.string(3), modelRequested: r.string(4),
                             modelServed: r.string(5), requestSHA256: r.string(6), promptVersion: r.string(7),
                             decision: d?.decision.rawValue, approver: d?.approver, reason: d?.reason)
        }
        let refused = await has(db, "case_ai_rejected_writes")
            ? Int(try await db.query("SELECT COUNT(*) FROM case_ai_rejected_writes WHERE upper(case_id) = upper(?);", [cid]).first?.int(0) ?? 0) : 0
        let exchanges = await has(db, "case_ai_run_exchanges")
            ? Int(try await db.query("SELECT COUNT(*) FROM case_ai_run_exchanges WHERE upper(case_id) = upper(?);", [cid]).first?.int(0) ?? 0) : 0

        // The outbound log for this case (rows carrying the case marker).
        var outbound: [String: Int] = [:]
        let marker = OnlineCloudProvider.caseMarker(caseID)
        for r in try await db.query("SELECT outcome, COUNT(*), COALESCE(SUM(bytes_sent),0) FROM outbound_log WHERE instr(detail, ?) > 0 OR instr(payload_text, ?) > 0 GROUP BY outcome;",
                                    [.text(marker), .text(marker)]) {
            outbound[r.string(0) ?? "?"] = Int(r.int(1) ?? 0)
            outbound["bytes sent", default: 0] += Int(r.int(2) ?? 0)
        }

        let revisions: [Revision] = try await db.query("""
            SELECT record_kind, change, actor, reason, recorded_at FROM case_record_revisions WHERE case_id = ? ORDER BY recorded_at;
            """, [cid]).map { Revision(recordKind: $0.string(0) ?? "", change: $0.string(1) ?? "", actor: $0.string(2) ?? "", reason: $0.string(3), at: iso($0.date(4))) }
        let access: [Access] = try await db.query("""
            SELECT kind, actor, occurred_at, recorded_tz FROM case_access_events WHERE upper(case_id) = upper(?) ORDER BY occurred_at;
            """, [cid]).map { Access(kind: $0.string(0) ?? "", actor: $0.string(1) ?? "", at: iso($0.date(2)), zone: $0.string(3) ?? "") }
        let jumps = Int(try await db.query("SELECT COUNT(*) FROM clock_events;", []).first?.int(0) ?? 0)
        var zones = Set<String>()
        for sql in ["SELECT DISTINCT recorded_tz FROM case_actions WHERE case_id = ? AND recorded_tz IS NOT NULL;",
                    "SELECT DISTINCT recorded_tz FROM case_access_events WHERE upper(case_id) = upper(?);"] {
            for r in try await db.query(sql, [cid]) { if let z = r.string(0) { zones.insert(z) } }
        }

        // Coverage: the case's documents the AI case picture has not read, and why.
        var notRead: [NotRead] = []
        let read = Set(try await db.query("SELECT upper(document_id) FROM case_ai_picture_documents WHERE upper(case_id) = upper(?);", [cid]).compactMap { $0.string(0) })
        let failed = Set(CasePictureFailures.shared.documents(caseID: caseID).map { $0.uuidString.uppercased() })
        let names = Dictionary(documents.map { ($0.fileID.uppercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
        for file in documents.map(\.fileID) {
            for r in try await db.query("SELECT upper(id) FROM knowledge_objects WHERE upper(file_id) = upper(?);", [.text(file)]) {
                guard let obj = r.string(0), !read.contains(obj) else { continue }
                let why = failed.contains(obj) ? "a case-picture part failed; it is read again on the next question" : "not read by the AI case picture yet (no AI read has run, or AI is not set up)"
                notRead.append(NotRead(document: names[file.uppercased()] ?? file, why: why))
            }
        }

        // Legal holds and erasures.
        var holds: [String] = []
        for r in try await db.query("SELECT custodian, issued_at, released_at FROM case_hold_notices WHERE case_id = ?;", [cid]) {
            holds.append("Hold notice to \(r.string(0) ?? "custodian") issued \(ExportDateStyle.day(r.date(1)))" + (r.date(2).map { ", released \(ExportDateStyle.day($0))" } ?? ", in force"))
        }
        let held = Int(try await db.query("""
            SELECT COUNT(*) FROM legal_hold_items i JOIN legal_holds h ON h.id = i.hold_id
            WHERE h.released_at IS NULL AND i.removed_at IS NULL AND (upper(i.object_id) = upper(?)
               OR upper(i.object_id) IN (SELECT upper(source_ref) FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1));
            """, [cid, cid]).first?.int(0) ?? 0)
        if held > 0 { holds.append("\(held) item(s) of this case or its documents under a legal hold") }
        var erasures: [String] = []
        for r in try await db.query("SELECT scope, erased_by, erased_at, reason FROM case_erasures ORDER BY erased_at;", []) {
            erasures.append("\(r.string(0) ?? "") erasure by \(r.string(1) ?? "") on \(ExportDateStyle.day(r.date(2))): \(r.string(3) ?? "")")
        }

        // Backups, retention, key rotations, certifications, retracted transcripts.
        let practice = inputs.ledgerURL.flatMap { PracticeRestore.last(besideLedgerAt: $0) }
        let practiceLine = practice.map { ($0.ok ? "Last practice restore succeeded " : "Last practice restore FAILED ") + ExportDateStyle.day(Date(timeIntervalSince1970: $0.ranAt)) }
            ?? "No practice restore has run yet."
        var retention: [String: String] = [:]
        if await has(db, "retention_rules") {
            for e in try await RetentionRegister(database: db).entries() { retention[e.tableClass.label] = e.periodText }
        }
        let rotations = try await KeyRotation.records(db).map { "Keys rotated \(ExportDateStyle.stamp($0.rotatedAt)) by \($0.rotatedBy) (\($0.vaultResealed) originals re-sealed; chain key \($0.newChainKeyID))" }
        let certs = await has(db, "export_certifications")
            ? Int(try await db.query("SELECT COUNT(*) FROM export_certifications WHERE upper(case_id) = upper(?);", [cid]).first?.int(0) ?? 0) : 0
        let retracted = Int(try await db.query("SELECT COUNT(*) FROM conversations WHERE case_id = ? AND retracted_at IS NOT NULL;", [cid]).first?.int(0) ?? 0)

        let chainStatus = inputs.chain?.statusLine ?? (inputs.chainError.map { "The audit chain could not be checked: \($0)" } ?? "The audit chain is not available on this Mac.")
        var report = CaseIntegrityReport(
            caseID: caseID.uuidString, caseTitle: title, generatedAt: iso(now), generatedBy: inputs.actor, zone: TimeZone.current.identifier,
            statement: wording, summary: [], principles: [], chainStatus: chainStatus, chainIntact: inputs.chain?.isIntact,
            chainErasedRecorded: inputs.chain?.erasedRecordedCount ?? 0, documents: documents, aiRuns: runs, aiFindings: findings,
            refusedWrites: refused, aiExchanges: exchanges, outbound: outbound, revisions: revisions, access: access, clockJumps: jumps,
            zones: zones.sorted(), notRead: notRead, holds: holds, erasures: erasures, practiceRestore: practiceLine, retention: retention,
            keyRotations: rotations, certifications: certs, retractedTranscripts: retracted, ledgerEncrypted: inputs.ledgerEncrypted)
        report.principles = report.principleSections()
        report.summary = report.summaryLines()
        return report
    }

    // MARK: - Wording

    var mismatches: Int { documents.filter { $0.vaultCheck.contains("DOES NOT MATCH") || $0.custody["hash_mismatch", default: 0] > 0 }.count }
    var decided: Int { aiFindings.filter { $0.decision != nil }.count }
    var fallbacks: Int { aiRuns.filter { r in r.modelServed.map { !$0.isEmpty && $0 != r.modelRequested } ?? false }.count }

    func summaryLines() -> [String] {
        var out: [String] = []
        out.append(chainIntact == true ? "The audit chain checked intact now." : (chainIntact == false ? "The audit chain did NOT check intact: see Traceable." : "The audit chain could not be checked."))
        out.append("\(documents.count) document(s) in the case; \(mismatches == 0 ? "no original failed its hash check" : "\(mismatches) original(s) failed a hash check — see Accurate").")
        out.append("\(aiRuns.count) AI run(s) and \(aiFindings.count) AI finding(s); \(decided) decided by a person; \(refusedWrites) AI write(s) refused by the checker and kept.")
        out.append(notRead.isEmpty ? "Every document of the case was read by the AI case picture." : "\(notRead.count) document part(s) were not read by the AI case picture (listed under Complete, with why).")
        out.append(holds.isEmpty ? "No legal hold on this case." : "Legal holds: \(holds.count) line(s) under Secure.")
        out.append(practiceRestore)
        return out
    }

    func principleSections() -> [Principle] {
        let custodyTotals = documents.reduce(into: [String: Int]()) { acc, d in for (k, v) in d.custody { acc[k, default: 0] += v } }
        func c(_ k: String) -> Int { custodyTotals[k, default: 0] }
        let verified = documents.filter { $0.vaultCheck.hasPrefix("re-hashed now: matches") }.count
        return [
            Principle(name: "Attributable", lines: [
                "\(aiRuns.count) AI run(s), each with who asked and the model asked for; \(aiRuns.filter { !$0.requestedBy.isEmpty }.count) name the person.",
                "\(decided) of \(aiFindings.count) AI finding(s) carry a person's decision (approver named).",
                "\(access.count) access event(s) name who opened the case, an original or an export."]),
            Principle(name: "Legible", lines: [
                "\(refusedWrites) AI write(s) the checker refused are kept with its reason (Review AI findings).",
                "\(retractedTranscripts) Ask transcript(s) retracted and kept; only an erasure removes a transcript.",
                ExportDateStyle.zoneStatement()]),
            Principle(name: "Contemporaneous", lines: [
                "Recorder time zones on this case's log rows: \(zones.isEmpty ? "none recorded yet" : zones.joined(separator: ", ")).",
                "\(clockJumps) clock jump(s) recorded on this Mac (a wall clock that moved over two minutes against the monotonic clock)."]),
            Principle(name: "Original", lines: [
                "\(documents.filter { $0.sha256AtIntake != nil }.count) of \(documents.count) document(s) carry the SHA-256 recorded at intake; \(documents.filter { $0.vaultAddress != nil }.count) have a kept copy in the vault.",
                "\(certifications) exported copy/copies carry a certification (SHA-256 read back, sources, producer, time and zone)."]),
            Principle(name: "Accurate", lines: [
                "Kept originals re-hashed now: \(verified) match, \(documents.filter { $0.vaultCheck.contains("DOES NOT MATCH") }.count) do not, \(documents.filter { $0.vaultCheck.contains("missing") || $0.vaultCheck.contains("could not") }.count) could not be checked.",
                "Custody: \(c("hash_computed")) hash computed, \(c("hash_verified")) verified again, \(c("hash_mismatch")) mismatch.",
                "Every AI finding was stored only after its quote was found in the document it cites."]),
            Principle(name: "Complete", lines: [
                notRead.isEmpty ? "No document part is recorded as unread by the AI case picture." : "\(notRead.count) document part(s) not read by the AI case picture (listed below with why).",
                "\(revisions.count) revision(s) of case records kept with their earlier value; \(revisions.filter { $0.reason != nil }.count) carry a reason."]),
            Principle(name: "Consistent", lines: [
                "One ledger holds every record of the case; dates in this report are ISO 8601 with the zone stated; amounts carry their ISO currency code."]),
            Principle(name: "Enduring", lines: [
                ArchivalPDF.statement,
                retention.isEmpty ? "No retention register in this ledger." : "Retention register: " + retention.keys.sorted().map { "\($0): \(retention[$0] ?? "")" }.joined(separator: "; ") + "."]),
            Principle(name: "Available", lines: [practiceRestore]),
            Principle(name: "Traceable", lines: [
                chainStatus + (chainErasedRecorded > 0 ? " (\(chainErasedRecorded) row(s) removed by a recorded erasure)" : ""),
                "\(exchangesLine)",
                "Outbound log for this case: " + (outbound.isEmpty ? "nothing was sent online." : outbound.keys.sorted().map { "\($0) \(outbound[$0] ?? 0)" }.joined(separator: ", ") + "."),
                "Custody: \(c("acquired")) acquired, \(c("exported")) exported, \(c("disclosed")) disclosed."]),
            Principle(name: "Secure", lines: [
                ledgerEncrypted ? "The ledger is encrypted on disk (AES-256)." : "The ledger is not encrypted.",
                keyRotations.isEmpty ? "No key rotation recorded." : keyRotations.joined(separator: " "),
                holds.isEmpty ? "No legal hold on this case." : holds.joined(separator: "; "),
                erasures.isEmpty ? "No erasure recorded in this ledger." : "\(erasures.count) erasure(s) recorded in this ledger (content-free)."]),
            Principle(name: "Reliable", lines: [
                "\(fallbacks) AI run(s) answered by another model than the one asked for (each answer says so).",
                "\(aiRuns.filter { $0.state != "done" }.count) AI run(s) did not finish (failed, cancelled or stopped early) and are recorded as such."]),
        ]
    }

    var exchangesLine: String { "\(aiExchanges) AI reply and tool step(s) kept with their runs (What was sent)." }

    /// The report as text (Markdown headings and bullets; rendered to the archival PDF).
    public var markdown: String {
        var s = "# Data integrity report — \(caseTitle)\n\n"
        s += "\(Self.wording)\n\nProduced \(generatedAt) (\(zone)) by \(generatedBy).\n\n## Summary\n\n"
        s += summary.map { "- \($0)" }.joined(separator: "\n") + "\n"
        for p in principles {
            s += "\n## \(p.name)\n\n" + p.lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        s += "\n## Documents and custody\n\n"
        s += documents.isEmpty ? "- No document is in the case.\n" : documents.map { d in
            "- \(d.name): intake SHA-256 \(d.sha256AtIntake.map { String($0.prefix(16)) + "…" } ?? "not recorded"); \(d.vaultCheck); custody "
                + (d.custody.isEmpty ? "none recorded" : d.custody.keys.sorted().map { "\($0) \(d.custody[$0] ?? 0)" }.joined(separator: ", "))
        }.joined(separator: "\n") + "\n"
        s += "\n## AI runs\n\n" + (aiRuns.isEmpty ? "- None.\n" : aiRuns.map { r in
            "- \(r.startedAt) \(r.kind) by \(r.requestedBy): asked \(r.modelRequested), answered by \(r.modelServed ?? "not recorded"); prompt \(r.promptVersion ?? "not recorded"); \(r.state)"
        }.joined(separator: "\n") + "\n")
        s += "\n## AI findings and decisions\n\n" + (aiFindings.isEmpty ? "- None.\n" : aiFindings.map { f in
            "- \(f.text) — \(f.decision.map { "\($0) by \(f.approver ?? "?")" + (f.reason.map { ": \($0)" } ?? "") } ?? "not decided"); request SHA-256 \(f.requestSHA256.map { String($0.prefix(16)) + "…" } ?? "not recorded")"
        }.joined(separator: "\n") + "\n")
        s += "\n## Revisions with reasons\n\n" + (revisions.isEmpty ? "- None.\n" : revisions.map { "- \($0.at) \($0.recordKind) \($0.change) by \($0.actor)" + ($0.reason.map { ": \($0)" } ?? "") }.joined(separator: "\n") + "\n")
        s += "\n## Access log\n\n" + (access.isEmpty ? "- None.\n" : access.map { "- \($0.at) (\($0.zone)) \($0.kind) by \($0.actor)" }.joined(separator: "\n") + "\n")
        s += "\n## Not read, and why\n\n" + (notRead.isEmpty ? "- Nothing.\n" : notRead.map { "- \($0.document): \($0.why)" }.joined(separator: "\n") + "\n")
        return s
    }

    /// The evidence files' manifest (CSV): one line per document.
    public var manifestCSV: String {
        func q(_ s: String) -> String { CSVFormulaGuard.csvField(s, alwaysQuote: true) }
        var out = "document,file_id,source_version,sha256_at_intake,vault_address,vault_check,custody\r\n"
        for d in documents {
            let custody = d.custody.keys.sorted().map { "\($0)=\(d.custody[$0] ?? 0)" }.joined(separator: ";")
            out += [d.name, d.fileID, d.sourceVersion ?? "", d.sha256AtIntake ?? "", d.vaultAddress ?? "", d.vaultCheck, custody].map(q).joined(separator: ",") + "\r\n"
        }
        return out
    }

    public func json() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    // MARK: - Export

    public struct Exported: Sendable, Equatable {
        public let files: [URL]
        public let sidecarsWritten: Int
        public let encrypted: Bool
    }

    /// Write the report into a new folder inside `parent`: the archival PDF, the JSON and the manifest, each certified; or —
    /// with a password — one AES-256 ZIP holding the three files and a note on opening it.
    public func export(into parent: URL, password: String?, database: Database?) async throws -> Exported {
        let fm = FileManager.default
        let day = String(generatedAt.prefix(10))
        let safe = caseTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(60)
        guard let pdf = CaseReportDocumentRenderer.pdf(markdown) else { throw CocoaError(.fileWriteUnknown) }
        let parts = [ZIPArchiveWriter.Entry(path: "integrity-report.pdf", data: pdf), ZIPArchiveWriter.Entry(path: "integrity-report.json", data: try json()),
                     ZIPArchiveWriter.Entry(path: "evidence-manifest.csv", data: Data(manifestCSV.utf8))]
        let caseUUID = UUID(uuidString: caseID)
        if let password, !password.isEmpty {
            let note = ZIPArchiveWriter.Entry(path: "README.txt", data: Data((EncryptedZIP.viewerNote + "\n\n" + Self.wording + "\n").utf8))
            let zip = try EncryptedZIP.build(parts + [note], password: password)
            let url = parent.appendingPathComponent("Data integrity report – \(safe) – \(day).zip")
            try zip.write(to: url, options: .atomic)
            let c = await CertifiedCopy.certifyAndRecord(url, kind: .derived, sources: documents.compactMap(\.sourceVersion), producedBy: generatedBy,
                                                         expectedSHA256: CertifiedCopy.sha256(zip), caseID: caseUUID, database: database)
            return Exported(files: [url], sidecarsWritten: c.sidecarWritten ? 1 : 0, encrypted: true)
        }
        let folder = parent.appendingPathComponent("Data integrity report – \(safe) – \(day)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = [], sidecars = 0
        for p in parts {
            let url = folder.appendingPathComponent(p.path)
            try p.data.write(to: url, options: .atomic)
            let c = await CertifiedCopy.certifyAndRecord(url, kind: .derived, sources: documents.compactMap(\.sourceVersion), producedBy: generatedBy,
                                                         expectedSHA256: CertifiedCopy.sha256(p.data), caseID: caseUUID, database: database)
            urls.append(url); sidecars += c.sidecarWritten ? 1 : 0
        }
        return Exported(files: urls, sidecarsWritten: sidecars, encrypted: false)
    }
}
