//
//  CaseOutputService.swift
//  Kalsmritikosh
//
//  App Store completion instructions 2026-10-30 §4 — ONE door for case content that leaves the app
//  (file, clipboard, print, share): the case-file report and log, exhibit/custody/redaction lists,
//  statements, hold notices, person-data exports and ACH reports. Every route does the same things,
//  in this order, immediately before release (after any destination dialog):
//
//    1. FREEZE — read the case as it is now; re-verify every link and carried item (§2), so what is
//       printed is the ledger's current verification, not a cached one.
//    2. REVALIDATE — every citation's source version must still be in the case and accessible under
//       the export policy (the same `eligibleSourceVersions` every studio and job-result export uses).
//       A source removed, re-ingested or labelled privileged since the preview refuses the release.
//    3. PROTECT — the rendered text (titles, notes, quotes and free text alike) is scrubbed of
//       protected source identities and verified clean; a name that would survive refuses the release.
//    4. LABEL — a case-file report is a DRAFT until the recorded approval of that exact snapshot
//       (there is none for case files); a document built while custody could not be read says so.
//    5. RELEASE — a file is written atomically, read back and recorded with the digest of the bytes
//       on disk; copy/print/share record the digest of the released text (not the printer's or the
//       recipient's bytes, which the app never sees). A write that succeeds but cannot be recorded
//       leaves a resumable pending record beside the ledger and is reported as such, never as a
//       clean export. A cancelled or failed write is never an export.
//
//  Reuses the frozen-export building blocks (`StudioEvidenceContext`, `ProtectedIdentities.scrub`,
//  the read-back-then-record pattern of job-result and studio exports) rather than a second policy
//  engine. Records live in `case_document_outputs` (schema v168) and the case log.
//

import Foundation
import os

/// What is being released.
public nonisolated enum CaseOutputKind: String, Sendable, CaseIterable {
    case caseFileReport, caseLog, exhibitList, custodyReport, personDataExport, statement, holdNotice, redactionLog, achReport
    /// A Data Lab dataset (CSV / XLSX / DOCX / PDF), a Work Center run report, a studio briefing.
    case dataset, workCenterReport, studioBriefing
    /// Living case map M8: the map (PDF / PNG) with its relationship and evidence table, or the table alone.
    case caseMap

    /// Prose documents carry banners; CSV lists and binary documents do not.
    var isProse: Bool {
        switch self {
        case .caseLog, .exhibitList, .redactionLog, .dataset, .caseMap: return false
        default: return true
        }
    }
    /// Only a case-file report is a working draft of a findings document; the others are records.
    var carriesDraftBanner: Bool { self == .caseFileReport }
}

/// How it leaves the app.
public nonisolated enum CaseOutputRoute: String, Sendable { case file, clipboard, print, share }

public nonisolated enum CaseOutputStatus: String, Sendable { case released, written, recordPending, refused, failed }

public nonisolated enum CaseOutputError: LocalizedError, Equatable, Sendable {
    case caseGone
    case scopeUnavailable
    case custodyUnreadable
    case sourcesWithdrawn(Int)
    case protectedIdentityLeak(Int)
    case writtenBytesDiffer
    case writeFailed(String)
    case emptyContent
    /// N7 — the protected-identity register could not be read: nothing leaves.
    case protectionUnreadable

    public var errorDescription: String? {
        switch self {
        case .protectionUnreadable: return "Nothing was released: the register of protected source identities could not be read, so the content could not be checked for them."
        case .caseGone: return "Nothing was released: the case no longer exists."
        case .scopeUnavailable: return "Nothing was released: the case's access policy could not be read, so the content could not be re-checked."
        case .custodyUnreadable: return "Nothing was released: the custody record could not be read, and a custody report must not present an empty record."
        case .sourcesWithdrawn(let n): return "Nothing was released: \(n) cited source(s) are no longer cleared for export (removed from the case, re-ingested, or labelled privileged since the preview). Review the case and release again."
        case .protectedIdentityLeak(let n): return "Nothing was released: \(n) protected source identity(ies) would remain recoverable in the output."
        case .writtenBytesDiffer: return "The file on disk does not hold the released content (its SHA-256 differs), so it was not recorded as an export. Export again."
        case .writeFailed(let why): return "The file could not be written: \(why)"
        case .emptyContent: return "Nothing was released: the content is empty."
        }
    }
}

/// Frozen, revalidated, protected content — the exact bytes every route releases.
public nonisolated struct CaseOutputPackage: Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID?
    public let kind: CaseOutputKind
    public let route: CaseOutputRoute
    /// The released text (for a binary document: the protected text it was rendered from).
    public let text: String
    /// The exact bytes released (UTF-8 of `text`, or the rendered binary document).
    public let data: Data
    /// SHA-256 of `data` — the snapshot identity recorded with the release.
    public let digest: String
    /// Digest of the case's accessible source versions at the final check (nil: no case to check).
    public let scopeFingerprint: String?
    /// True only when a recorded approval covers exactly this snapshot (never, for case files).
    public let approved: Bool
    public let custodyIncomplete: Bool
    public let actor: String
    public let preparedAt: Date
    /// N6 — every citation the content rests on, re-checked at the moment of release.
    public var citations: [StudioEvidenceRef] = []
}

/// What happened to a release.
public nonisolated struct CaseOutputReceipt: Sendable, Equatable {
    public let id: UUID
    public let status: CaseOutputStatus
    public let fileName: String?
    public let fileSHA256: String?
    /// True when the ledger holds the record now; false when it is pending (or not retained).
    public let recorded: Bool
    /// When not recorded: a resumable pending record was kept beside the ledger.
    public let pendingRetained: Bool
    public let detail: String?

    public var summary: String {
        switch status {
        case .written:
            let base = "Exported \(fileName ?? "file") (SHA-256 \((fileSHA256 ?? "").prefix(12))…)"
            return recorded ? base + ", recorded." : base + " — NOT yet recorded: \(detail ?? "")"
        case .released:
            return recorded ? "Released and recorded." : "Released — NOT yet recorded: \(detail ?? "")"
        case .recordPending:
            return "\(fileName.map { "Exported \($0)" } ?? "Released") but the record could not be saved" + (pendingRetained ? "; it is kept and will be recorded at the next launch." : " and could not be retained: \(detail ?? "")")
        case .refused: return detail ?? "Refused."
        case .failed: return detail ?? "Failed."
        }
    }
}

/// A recorded release.
public nonisolated struct CaseOutputRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let caseID: UUID
    public let kind: CaseOutputKind
    public let route: CaseOutputRoute
    public let snapshotSHA256: String
    public let fileName: String?
    public let fileSHA256: String?
    public let status: CaseOutputStatus
    public let detail: String?
    public let releasedBy: String
    public let releasedAt: Date
}

public actor CaseOutputService {
    public typealias CustodyLoader = @Sendable (_ caseID: UUID) async throws -> [CustodyManifestEntry]

    /// Test hooks: a fault injected into the ledger record (the file is written, the record fails);
    /// a change made to the file between the write and the read-back.
    public struct Hooks: Sendable {
        public var recordFault: (@Sendable () throws -> Void)?
        public var afterWrite: (@Sendable (URL) throws -> Void)?
        public init(recordFault: (@Sendable () throws -> Void)? = nil, afterWrite: (@Sendable (URL) throws -> Void)? = nil) {
            self.recordFault = recordFault; self.afterWrite = afterWrite
        }
    }

    private let database: Database
    private let caseFiles: CaseFileService
    private let custody: CustodyLoader
    private let context: CaseEvidenceVerifier.ContextLoader
    private let results: JobResultRepository
    /// Where a release that could not be recorded keeps its pending record (beside the ledger).
    public nonisolated let pendingDirectory: URL
    private var hooks = Hooks()

    public init(database: Database, caseFiles: CaseFileService, custody: @escaping CustodyLoader, pendingDirectory: URL) {
        self.database = database
        self.caseFiles = caseFiles
        self.custody = custody
        self.context = caseFiles.verifier.context
        self.results = JobResultRepository(database: database)
        self.pendingDirectory = pendingDirectory
    }

    public func setHooks(_ h: Hooks) { hooks = h }

    static let draftBanner = "> DRAFT case file — not an approved findings report.\n\n"
    static let custodyBanner = "> INCOMPLETE — the custody record could not be read when this was released.\n\n"

    // MARK: - Prepare (freeze + revalidate + protect)

    /// Freeze a case document: the case as it is NOW, every link and carried item re-verified, every
    /// citation's source still cleared, the rendered text scrubbed of protected identities.
    public func prepare(caseID: UUID, kind: CaseOutputKind, route: CaseOutputRoute, actor: String,
                        render: @Sendable (CaseFileSnapshot) -> String) async throws -> CaseOutputPackage {
        do {
            guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
            var custodyIncomplete = false
            var manifest: [CustodyManifestEntry] = []
            do { manifest = try await custody(caseID) } catch {
                custodyIncomplete = true
                KalsmritikoshLog.app.error("Case output: custody read failed: \(String(describing: error), privacy: .public)")
            }
            if kind == .custodyReport, custodyIncomplete { throw CaseOutputError.custodyUnreadable }
            // 1. Freeze with fresh verification states.
            try await caseFiles.reverifyLinks(caseID: caseID)
            try await caseFiles.reverifyCarriedItems(caseID: caseID)
            guard let snapshot = try await caseFiles.snapshot(caseID: caseID, custody: manifest) else { throw CaseOutputError.caseGone }
            // 2. Revalidate every cited source against the case's access policy as it is now.
            var citations = snapshot.grid.compactMap(\.passage) + snapshot.journal.flatMap(\.citations) + snapshot.reportItems.flatMap(\.citations)
                + snapshot.journal.compactMap { $0.evidenceRef.flatMap(UUID.init(uuidString:)).map { StudioEvidenceRef(sourceVersionID: $0, quote: nil) } }
            // S4 (REPORT-03): a case-file report carries the supplied reports and their points, each printed with EVERY
            // qualification — a conditional result cannot leave the app as an unconditional finding. Their passages are
            // re-checked with the rest.
            var reportSection = ""
            if kind == .caseFileReport {
                let ledger = try await caseFiles.file.reportLedger(caseID: caseID)
                let structure = try await caseFiles.file.reportStructure(caseID: caseID)
                reportSection = CaseReportPointText.section(ledger, structure: structure)
                citations += ledger.points.filter(\.isActive).compactMap(\.passage).filter { $0.sourceVersionID != nil }
            }
            let fingerprint = try await revalidate(caseID: caseID, citations: citations)
            // 3. Render once; label; protect.
            var text = render(snapshot) + reportSection
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaseOutputError.emptyContent }
            if kind.isProse, custodyIncomplete { text = Self.custodyBanner + text }
            if kind.carriesDraftBanner { text = Self.draftBanner + text }
            text = try await protect(text)
            return CaseOutputPackage(id: UUID(), caseID: caseID, kind: kind, route: route, text: text, data: Data(text.utf8), digest: StudioRecordRepository.sha256(Data(text.utf8)),
                                     scopeFingerprint: fingerprint, approved: false, custodyIncomplete: custodyIncomplete, actor: actor, preparedAt: Date(),
                                     citations: citations)
        } catch {
            await recordRefusal(caseID: caseID, kind: kind, route: route, actor: actor, error)
            throw error
        }
    }

    /// Freeze free text that is not a case-file document (an ACH report, a hold notice): its
    /// citations are revalidated against the case (when it has one) and the text is protected.
    public func prepareText(caseID: UUID?, kind: CaseOutputKind, route: CaseOutputRoute, actor: String,
                            citations: [StudioEvidenceRef], text raw: String) async throws -> CaseOutputPackage {
        do {
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaseOutputError.emptyContent }
            var fingerprint: String?
            if let caseID {
                guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
                fingerprint = try await revalidate(caseID: caseID, citations: citations)
            }
            let text = try await protect(raw)
            return CaseOutputPackage(id: UUID(), caseID: caseID, kind: kind, route: route, text: text, data: Data(text.utf8), digest: StudioRecordRepository.sha256(Data(text.utf8)),
                                     scopeFingerprint: fingerprint, approved: false, custodyIncomplete: false, actor: actor, preparedAt: Date(),
                                     citations: citations)
        } catch {
            if let caseID { await recordRefusal(caseID: caseID, kind: kind, route: route, actor: actor, error) }
            throw error
        }
    }

    /// Freeze a binary document (XLSX / DOCX / PDF) rendered by the caller from text the service
    /// protected first (`protectedText`): `texts` are everything that went into the rendering, checked
    /// again for a protected identity before the bytes are released. Citations are revalidated
    /// against the case when there is one.
    public func prepareData(caseID: UUID?, kind: CaseOutputKind, route: CaseOutputRoute, actor: String,
                            citations: [StudioEvidenceRef], texts: [String], data: Data) async throws -> CaseOutputPackage {
        do {
            guard !data.isEmpty else { throw CaseOutputError.emptyContent }
            var fingerprint: String?
            if let caseID {
                guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
                fingerprint = try await revalidate(caseID: caseID, citations: citations)
            }
            let names = try await protectedNames()
            let joined = texts.joined(separator: "\n")
            let leaks = RedactionVerifier().leaks(in: joined, protectedTerms: names, artifact: "export")
            guard leaks.isEmpty else { throw CaseOutputError.protectedIdentityLeak(leaks.count) }
            return CaseOutputPackage(id: UUID(), caseID: caseID, kind: kind, route: route, text: joined, data: data, digest: StudioRecordRepository.sha256(data),
                                     scopeFingerprint: fingerprint, approved: false, custodyIncomplete: false, actor: actor, preparedAt: Date(),
                                     citations: citations)
        } catch {
            if let caseID { await recordRefusal(caseID: caseID, kind: kind, route: route, actor: actor, error) }
            throw error
        }
    }

    /// Living case map M8 — freeze a map export: the shown items and links, the legend, the case, the moment or
    /// recorded state, the scope and the sources; the restrictions that apply NOW (the case's legal holds as they
    /// are now; protected identities scrubbed from every text before anything is drawn); then the bytes are
    /// rendered from the protected text and go through `prepareData` (every cited source re-checked against the
    /// export policy now, the rendered texts checked again for a protected name). `write` / `release` re-check
    /// at the moment of release. For `.png` the table is a second package (`.csv`) the caller releases with it.
    public func prepareMap(_ request: CaseMapExportRequest, format: CaseMapExportFormat, route: CaseOutputRoute, actor: String) async throws -> CaseOutputPackage {
        let caseID = request.projection.caseID
        let frozen: CaseMapExportFrozen
        let csv: String
        let rendered: Data
        do {
            guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
            let holds = try await currentHoldLines(caseID: caseID)
            let raw = CaseMapExportRenderer.freeze(request, restrictions: holds + [
                "Protected source identities are removed from this export, as from every export.",
                "Every cited source was re-checked against this case's export policy at the moment of release."])
            guard !raw.items.isEmpty else { throw CaseOutputError.emptyContent }
            var cache: [String: String] = [:]
            let names = try await protectedNames()
            frozen = try raw.mapped { text in
                if let hit = cache[text] { return hit }
                let scrubbed = ProtectedIdentities.scrub(text, names: names)
                guard scrubbed.leaks.isEmpty else { throw CaseOutputError.protectedIdentityLeak(scrubbed.leaks.count) }
                cache[text] = scrubbed.text
                return scrubbed.text
            }
            let points = CaseMapExportRenderer.points(request)
            csv = CaseMapExportRenderer.csv(frozen)
            switch format {
            case .pdf: rendered = CaseMapExportRenderer.pdf(frozen, placements: points)
            case .png: rendered = CaseMapExportRenderer.png(frozen, placements: points)
            case .csv: rendered = Data(csv.utf8)
            }
        } catch {
            await recordRefusal(caseID: caseID, kind: .caseMap, route: route, actor: actor, error)
            throw error
        }
        // A file carries the rendering; a copy or print releases the table's text. prepareData records its refusals.
        let data = route == .file ? rendered : Data(csv.utf8)
        let pkg = try await prepareData(caseID: caseID, kind: .caseMap, route: route, actor: actor, citations: frozen.citations,
                                        texts: [csv] + frozen.texts, data: data)
        guard route != .file else { return pkg }
        return CaseOutputPackage(id: pkg.id, caseID: pkg.caseID, kind: pkg.kind, route: pkg.route, text: csv, data: data, digest: pkg.digest,
                                 scopeFingerprint: pkg.scopeFingerprint, approved: false, custodyIncomplete: false, actor: actor,
                                 preparedAt: pkg.preparedAt, citations: pkg.citations)
    }

    /// The case's legal holds as they are now (stated on every map export, current or historical).
    private func currentHoldLines(caseID: UUID) async throws -> [String] {
        let notices = Int(try await database.query("SELECT COUNT(*) FROM case_hold_notices WHERE case_id = ? AND released_at IS NULL;", [.uuid(caseID)]).first?.int(0) ?? 0)
        let ids = [caseID.uuidString, caseID.uuidString.lowercased()]
        let held = Int(try await database.query("""
            SELECT COUNT(*) FROM legal_hold_items i JOIN legal_holds h ON h.id = i.hold_id
            WHERE h.released_at IS NULL AND i.removed_at IS NULL AND (i.object_id IN (?, ?)
               OR i.object_id IN (SELECT source_ref FROM investigation_case_sources WHERE case_id = ? AND in_scope = 1));
            """, ids.map { .text($0) } + [.uuid(caseID)]).first?.int(0) ?? 0)
        if notices == 0 && held == 0 { return ["Legal holds now: none on this case or its documents."] }
        return ["Legal holds now: \(notices) unreleased hold notice(s) and \(held) held item(s) on this case or its documents. They stay in force; this export does not change them."]
    }

    /// Scrub protected identities from text that will be rendered into a binary document; a name
    /// that would survive throws. The caller renders from the returned text and passes it back to
    /// `prepareData` as one of `texts`.
    public func protectedText(_ text: String) async throws -> String { try await protect(text) }

    /// Every cited version must be eligible under the export policy now. Returns the scope fingerprint.
    private func revalidate(caseID: UUID, citations: [StudioEvidenceRef]) async throws -> String {
        guard let ctx = await context(caseID) else { throw CaseOutputError.scopeUnavailable }
        let cited = Set(citations.compactMap(\.sourceVersionID))
        let withdrawn = cited.subtracting(ctx.eligibleSourceVersions)
        guard withdrawn.isEmpty else { throw CaseOutputError.sourcesWithdrawn(withdrawn.count) }
        return StudioRecordRepository.sha256(Data(ctx.eligibleSourceVersions.map(\.uuidString).sorted().joined(separator: ",").utf8))
    }

    /// Protected source identities never leave the app — in titles, notes, quotes or free text.
    private func protect(_ text: String) async throws -> String {
        let names = try await protectedNames()
        let scrubbed = ProtectedIdentities.scrub(text, names: names)
        guard scrubbed.leaks.isEmpty else { throw CaseOutputError.protectedIdentityLeak(scrubbed.leaks.count) }
        return scrubbed.text
    }

    /// The protected-identity register, read fail-closed (N7): unreadable is an error, never "no names".
    private func protectedNames() async throws -> [String] {
        do { return try await results.protectedIdentityNames() } catch {
            KalsmritikoshLog.app.error("Case output: protected-identity register unreadable: \(String(describing: error), privacy: .public)")
            throw CaseOutputError.protectionUnreadable
        }
    }

    // MARK: - Release

    /// N6 — the authoritative check at the moment content leaves, inside the operation that releases it:
    /// the case still exists (not erased), every cited source is still cleared for export, the protection
    /// register is readable and no name protected NOW appears in the content. A package prepared before a
    /// source was withdrawn, a name protected or the case erased is refused here, not released.
    func authorizeRelease(_ pkg: CaseOutputPackage) async throws {
        if let caseID = pkg.caseID {
            guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
            _ = try await revalidate(caseID: caseID, citations: pkg.citations)
        }
        let names = try await protectedNames()
        let leaks = RedactionVerifier().leaks(in: pkg.text, protectedTerms: names, artifact: "export")
        guard leaks.isEmpty else { throw CaseOutputError.protectedIdentityLeak(leaks.count) }
    }

    private func refused(_ pkg: CaseOutputPackage, _ error: Error) async -> CaseOutputReceipt {
        if let caseID = pkg.caseID { await recordRefusal(caseID: caseID, kind: pkg.kind, route: pkg.route, actor: pkg.actor, error) }
        return CaseOutputReceipt(id: pkg.id, status: .refused, fileName: nil, fileSHA256: nil, recorded: pkg.caseID != nil, pendingRetained: false,
                                 detail: error.localizedDescription)
    }

    /// Write the package to `url` atomically, read it back, and record the digest of the bytes on
    /// disk. A mismatch or a write error is recorded as failed and is not an export. Nothing is written
    /// unless the release is authorised now (N6).
    public func write(_ pkg: CaseOutputPackage, to url: URL) async -> CaseOutputReceipt {
        do { try await authorizeRelease(pkg) } catch { return await refused(pkg, error) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try pkg.data.write(to: url, options: .atomic)
        } catch {
            let why = CaseOutputError.writeFailed(error.localizedDescription)
            KalsmritikoshLog.app.error("Case output write failed: \(error.localizedDescription, privacy: .public)")
            return await record(pkg, status: .failed, fileName: url.lastPathComponent, fileSHA256: nil, detail: why.errorDescription)
        }
        do { try hooks.afterWrite?(url) } catch {
            KalsmritikoshLog.app.error("Case output test hook failed: \(error.localizedDescription, privacy: .public)")
        }
        guard let written = try? Data(contentsOf: url), StudioRecordRepository.sha256(written) == pkg.digest else {
            return await record(pkg, status: .failed, fileName: url.lastPathComponent, fileSHA256: (try? Data(contentsOf: url)).map { StudioRecordRepository.sha256($0) },
                                detail: CaseOutputError.writtenBytesDiffer.errorDescription)
        }
        return await record(pkg, status: .written, fileName: url.lastPathComponent, fileSHA256: pkg.digest, detail: nil)
    }

    /// Copy, print or share (N6): authorise first, then `deliver` puts the protected text on the clipboard,
    /// the printer or the share sheet (true when it actually left — a cancelled print dialog is false), then
    /// the release is recorded. Nothing is handed to `deliver` when the release is refused, so a log can
    /// never follow a disclosure that should not have happened. The digest recorded is that of the
    /// released text; the app never sees the printer's or the recipient's bytes.
    public func release(_ pkg: CaseOutputPackage, deliver: @MainActor @Sendable (String) -> Bool) async -> CaseOutputReceipt {
        do { try await authorizeRelease(pkg) } catch { return await refused(pkg, error) }
        guard await deliver(pkg.text) else {
            return CaseOutputReceipt(id: pkg.id, status: .failed, fileName: nil, fileSHA256: nil, recorded: false, pendingRetained: false,
                                     detail: "Not released (cancelled or not available); nothing was recorded.")
        }
        return await record(pkg, status: .released, fileName: nil, fileSHA256: nil,
                            detail: "\(pkg.route.rawValue): digest of the released text, not of the \(pkg.route == .print ? "printer's" : "recipient's") bytes")
    }

    // MARK: - Records

    private struct PendingRecord: Codable {
        var id: UUID, caseID: UUID, kind: String, route: String, snapshotSHA256: String, fileName: String?, fileSHA256: String?
        var status: String, detail: String?, releasedBy: String, releasedAt: Date, logDetail: String
    }

    private func record(_ pkg: CaseOutputPackage, status: CaseOutputStatus, fileName: String?, fileSHA256: String?, detail: String?) async -> CaseOutputReceipt {
        guard let caseID = pkg.caseID else {
            // Content with no case (an unfiled ACH analysis): protected, but there is no case log to
            // record it in. Said so in the receipt rather than inventing a case.
            KalsmritikoshLog.app.info("Case output without a case released via \(pkg.route.rawValue, privacy: .public) (\(pkg.kind.rawValue, privacy: .public)); not recorded in any case")
            return CaseOutputReceipt(id: pkg.id, status: status, fileName: fileName, fileSHA256: fileSHA256, recorded: false, pendingRetained: false,
                                     detail: (detail.map { $0 + "; " } ?? "") + "no case to record it in")
        }
        let logDetail = "\(pkg.kind.rawValue) · \(pkg.route.rawValue)" + (fileName.map { " · \($0)" } ?? "") + " · sha256 \((fileSHA256 ?? pkg.digest).prefix(16))"
            + (pkg.custodyIncomplete ? " · custody incomplete" : "")
        // One record per release attempt (the same package may be written twice, or fail then succeed).
        let pending = PendingRecord(id: UUID(), caseID: caseID, kind: pkg.kind.rawValue, route: pkg.route.rawValue, snapshotSHA256: pkg.digest,
                                    fileName: fileName, fileSHA256: fileSHA256, status: status.rawValue, detail: detail, releasedBy: pkg.actor,
                                    releasedAt: Date(), logDetail: logDetail)
        do {
            try hooks.recordFault?()
            try await insert(pending)
            return CaseOutputReceipt(id: pending.id, status: status, fileName: fileName, fileSHA256: fileSHA256, recorded: true, pendingRetained: false, detail: detail)
        } catch {
            KalsmritikoshLog.app.error("Case output record failed: \(String(describing: error), privacy: .public)")
            let retained = retain(pending)
            let why = "the record could not be saved (\(error.localizedDescription))"
            return CaseOutputReceipt(id: pending.id, status: status == .written || status == .released ? .recordPending : status, fileName: fileName,
                                     fileSHA256: fileSHA256, recorded: false, pendingRetained: retained, detail: retained ? why : why + "; the pending record could not be kept either")
        }
    }

    private func insert(_ r: PendingRecord) async throws {
        try await database.withSavepoint("case_output_\(r.id.uuidString.prefix(8))") { db in
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(r.caseID)]).isEmpty else { throw CaseOutputError.caseGone }
            try db.exec("""
                INSERT OR IGNORE INTO case_document_outputs (id, case_id, kind, route, snapshot_sha256, file_name, file_sha256, status, detail, released_by, released_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(r.id), .uuid(r.caseID), .text(r.kind), .text(r.route), .text(r.snapshotSHA256), .optionalText(r.fileName), .optionalText(r.fileSHA256),
                      .text(r.status), .optionalText(r.detail), .text(r.releasedBy), .date(r.releasedAt)])
        }
        let action: String
        switch CaseOutputStatus(rawValue: r.status) ?? .failed {
        case .written, .released: action = "exported"
        case .refused: action = "exportRefused"
        case .failed, .recordPending: action = "exportFailed"
        }
        try await caseFiles.file.logAction(caseID: r.caseID, action: action, detail: r.logDetail + (r.detail.map { " · \($0)" } ?? ""), actor: r.releasedBy, at: r.releasedAt)
    }

    private func recordRefusal(caseID: UUID, kind: CaseOutputKind, route: CaseOutputRoute, actor: String, _ error: Error) async {
        let pending = PendingRecord(id: UUID(), caseID: caseID, kind: kind.rawValue, route: route.rawValue, snapshotSHA256: "", fileName: nil, fileSHA256: nil,
                                    status: CaseOutputStatus.refused.rawValue, detail: error.localizedDescription, releasedBy: actor, releasedAt: Date(),
                                    logDetail: "\(kind.rawValue) · \(route.rawValue)")
        do { try await insert(pending) } catch {
            KalsmritikoshLog.app.error("Case output refusal not recorded: \(String(describing: error), privacy: .public)")
        }
    }

    /// Keep a record that could not be written to the ledger, beside the ledger, for `resumePending`.
    private func retain(_ r: PendingRecord) -> Bool {
        do {
            try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(r)
            try data.write(to: pendingDirectory.appendingPathComponent("\(r.id.uuidString).json"), options: .atomic)
            return true
        } catch {
            KalsmritikoshLog.app.error("Case output pending record not retained: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Record every retained pending release (at launch, and before new records). Returns how many landed.
    @discardableResult
    public func resumePending() async -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil) else { return 0 }
        var landed = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let r = try? JSONDecoder().decode(PendingRecord.self, from: data) else { continue }
            do {
                try await insert(r)
                try? FileManager.default.removeItem(at: file)
                landed += 1
            } catch {
                KalsmritikoshLog.app.error("Case output pending record still not recorded: \(String(describing: error), privacy: .public)")
            }
        }
        return landed
    }

    /// The case's recorded releases, newest first.
    public func outputs(caseID: UUID) async throws -> [CaseOutputRecord] {
        try await database.query("""
            SELECT id, case_id, kind, route, snapshot_sha256, file_name, file_sha256, status, detail, released_by, released_at
            FROM case_document_outputs WHERE case_id = ? ORDER BY released_at DESC;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let kind = r.string(2).flatMap(CaseOutputKind.init(rawValue:)),
                  let route = r.string(3).flatMap(CaseOutputRoute.init(rawValue:)), let sha = r.string(4),
                  let status = r.string(7).flatMap(CaseOutputStatus.init(rawValue:)), let by = r.string(9), let at = r.date(10) else { return nil }
            return CaseOutputRecord(id: id, caseID: c, kind: kind, route: route, snapshotSHA256: sha, fileName: r.string(5), fileSHA256: r.string(6),
                                    status: status, detail: r.string(8), releasedBy: by, releasedAt: at)
        }
    }
}
