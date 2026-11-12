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
    /// S11 (OUTPUT-01..05) — the portable read-only case package (one static HTML file), a review case's own record, the
    /// money report, a briefing, and the findings report of the work-product hand-off.
    case casePackage, reviewRecord, moneyReport, briefing, findingsReport
    /// S11 (OUTPUT-01) — a persona studio's report of a case draft, and a job result of the case: their own writers put the
    /// bytes out, but they are prepared, authorised and recorded here.
    case studioReport, jobResult

    /// Prose documents carry banners; CSV lists and binary documents do not.
    var isProse: Bool {
        switch self {
        case .caseLog, .exhibitList, .redactionLog, .dataset, .caseMap, .casePackage: return false
        default: return true
        }
    }
    /// Only a case-file report is a working draft of a findings document; the others are records.
    var carriesDraftBanner: Bool { self == .caseFileReport }
    /// S11 (OUTPUT-08) — outputs that present conclusions: each carries its revision and either the approval of exactly that
    /// revision or a DRAFT statement, and an approval that no longer matches the case refuses the release.
    public var presentsConclusions: Bool { [.caseFileReport, .casePackage, .reviewRecord, .moneyReport, .briefing, .findingsReport].contains(self) }
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
    /// S11 (OUTPUT-02) — the case kept changing while it was being read: no mixed-state output is made.
    case keptChanging
    /// S11 (OUTPUT-07) — the file's bytes match, but its content does not reconcile with its manifest.
    case writtenContentDiffers(String)
    /// S11 (OUTPUT-08) — the approval the output was prepared under was withdrawn, or the case changed since.
    case approvalNoLongerCurrent(String)
    /// S11 (OUTPUT-08) — the case changed after this output was prepared; it would present a stale state as current.
    case changedSincePrepared
    /// S11 (OUTPUT-08) — an approval could not be recorded.
    case approvalRefused(String)
    /// S11 (OUTPUT-05) — the package's text would carry active content (a script, an external fetch).
    case unsafePackage(String)

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
        case .keptChanging: return "Nothing was released: the case kept changing while it was being read, so no consistent output could be made. Try again when the change has finished."
        case .writtenContentDiffers(let why): return "The file was written but its content does not reconcile with its manifest (\(why)), so it was not recorded as an export. Export again."
        case .approvalNoLongerCurrent(let why): return "Nothing was released: \(why) Approve the case as it is now, or release it as a draft."
        case .changedSincePrepared: return "Nothing was released: the case changed after this output was prepared, so it would present an earlier state as current. Prepare it again."
        case .approvalRefused(let why): return "The approval was not recorded: \(why)"
        case .unsafePackage(let why): return "Nothing was released: the package would contain active content (\(why))."
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
    /// S11 (OUTPUT-02 / OUTPUT-07) — what was frozen: the revision fence, selection, counts and pinned revisions, reconciled
    /// against the written file before the release is recorded.
    public var manifest: CaseOutputManifest? = nil
    /// S11 (OUTPUT-08) — the approval of exactly this revision the output was prepared under (nil: a draft).
    public var approvalID: UUID? = nil
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
        /// S11 — runs between the two fence reads of a freeze (a concurrent edit lands here in tests).
        public var duringFreeze: (@Sendable () async -> Void)?
        public init(recordFault: (@Sendable () throws -> Void)? = nil, afterWrite: (@Sendable (URL) throws -> Void)? = nil,
                    duringFreeze: (@Sendable () async -> Void)? = nil) {
            self.recordFault = recordFault; self.afterWrite = afterWrite; self.duringFreeze = duringFreeze
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
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        do {
            guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
            try await requireExport(caseID: caseID, actor: actor)
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
            // S11 (OUTPUT-02) — the snapshot is read in several steps; it is one state only when the case's revision fence is the
            // same before and after the read. A change in between reads again (three times), then refuses: never a mixed state.
            var frozenSnapshot: CaseFileSnapshot?
            var frozenFence: String?
            for _ in 1...3 {
                let before = try await outputFence(caseID: caseID)
                guard let read = try await caseFiles.snapshot(caseID: caseID, custody: manifest) else { throw CaseOutputError.caseGone }
                if let hook = hooks.duringFreeze { await hook() }
                if try await outputFence(caseID: caseID) == before { frozenSnapshot = read; frozenFence = before; break }
            }
            guard let snapshot = frozenSnapshot, let fence = frozenFence else { throw CaseOutputError.keptChanging }
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
            // S11 (OUTPUT-08) — the approval of exactly this revision, or the DRAFT banner with the revision.
            let stamp = try await conclusionStamp(caseID: caseID, kind: kind, fence: fence)
            if kind.presentsConclusions { text = stamp.line + text }
            if kind.carriesDraftBanner, stamp.approvalID == nil { text = Self.draftBanner + text }
            text = try await protect(text)
            var pkg = CaseOutputPackage(id: UUID(), caseID: caseID, kind: kind, route: route, text: text, data: Data(text.utf8), digest: StudioRecordRepository.sha256(Data(text.utf8)),
                                        scopeFingerprint: fingerprint, approved: stamp.approvalID != nil, custodyIncomplete: custodyIncomplete, actor: actor, preparedAt: Date(),
                                        citations: citations)
            pkg.approvalID = stamp.approvalID
            pkg.manifest = CaseOutputManifest(caseID: caseID, kind: kind, revisionFence: fence, scopeFingerprint: fingerprint, readAt: pkg.preparedAt,
                                              selection: "The whole case file as recorded", format: "text",
                                              counts: ["allegations": snapshot.allegations.count, "evidenceLinks": snapshot.grid.count, "chronology": snapshot.journal.count,
                                                       "tasks": snapshot.tasks.count, "people": snapshot.people.count, "exhibits": snapshot.exhibits.count,
                                                       "reportItems": snapshot.reportItems.count],
                                              pinned: [:], sourceVersions: Set(citations.compactMap(\.sourceVersionID)).map(\.uuidString).sorted(), omitted: [:],
                                              approval: stamp.approvalID?.uuidString, state: stamp.approvalID == nil ? "draft" : "approved")
            return pkg
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
                try await requireExport(caseID: caseID, actor: actor)
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
                try await requireExport(caseID: caseID, actor: actor)
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
            try await requireExport(caseID: caseID, actor: actor)
            let holds = try await currentHoldLines(caseID: caseID)
            let raw = CaseMapExportRenderer.freeze(request, restrictions: holds + [
                "Protected source identities are removed from this export, as from every export.",
                "Every cited source was re-checked against this case's export policy at the moment of release."])
            guard !raw.items.isEmpty else { throw CaseOutputError.emptyContent }
            var cache: [String: String] = [:]
            let names = try await protectedNames()
            frozen = try raw.mapped { text in
                if let hit = cache[text] { return hit }
                // S9 (SEC-05) — a credential pasted into case text never leaves in an export.
        let scrubbed = ProtectedIdentities.scrub(SecretRedactor.redact(text), names: names)
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
        var pkg = try await prepareData(caseID: caseID, kind: .caseMap, route: route, actor: actor, citations: frozen.citations,
                                        texts: [csv] + frozen.texts, data: data)
        // S11 (OUTPUT-07) — what was frozen, so the written file is reconciled with it (rows, pages, image) before it is recorded.
        let manifest = try await mapManifest(request, frozen: frozen, format: format, route: route, scopeFingerprint: pkg.scopeFingerprint)
        guard route != .file else { pkg.manifest = manifest; return pkg }
        var out = CaseOutputPackage(id: pkg.id, caseID: pkg.caseID, kind: pkg.kind, route: pkg.route, text: csv, data: data, digest: pkg.digest,
                                    scopeFingerprint: pkg.scopeFingerprint, approved: false, custodyIncomplete: false, actor: actor,
                                    preparedAt: pkg.preparedAt, citations: pkg.citations)
        out.manifest = manifest
        return out
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
        // S9 (SEC-05) — a credential pasted into case text never leaves in an export.
        let scrubbed = ProtectedIdentities.scrub(SecretRedactor.redact(text), names: names)
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
    private func authorizeRelease(_ pkg: CaseOutputPackage) async throws {
        if let caseID = pkg.caseID {
            // S9 (SEC-12) — the person releasing must still be allowed to export from the case NOW: a role removed after
            // the package was prepared refuses the release, and nothing leaves.
            try await requireExport(caseID: caseID, actor: pkg.actor)
            guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
            _ = try await revalidate(caseID: caseID, citations: pkg.citations)
            // S11 (OUTPUT-08) — an output that presents conclusions is released only as the case still is: a change after it
            // was prepared refuses it, and an approval withdrawn since refuses it.
            try await requireCurrentRevision(pkg)
        }
        let names = try await protectedNames()
        let leaks = RedactionVerifier().leaks(in: pkg.text, protectedTerms: names, artifact: "export")
        guard leaks.isEmpty else { throw CaseOutputError.protectedIdentityLeak(leaks.count) }
    }

    /// The access check for an output of the case (ACCESS-03 / SEC-12), inside its own savepoint.
    private func requireExport(caseID: UUID, actor: String) async throws {
        try await database.withSavepoint("case_out_acl_\(UUID().uuidString.prefix(8))") { db in
            try CaseAccessPolicy.require(db, caseID: caseID, actor: actor, .export)
        }
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
        // S11 (OUTPUT-07) — the bytes on disk are parsed back and reconciled with the manifest (counts, format), not only hashed.
        if let manifest = pkg.manifest, let problem = CaseOutputArtifactCheck.problem(written, manifest: manifest) {
            KalsmritikoshLog.app.error("Case output read-back did not reconcile: \(problem, privacy: .public)")
            return await record(pkg, status: .failed, fileName: url.lastPathComponent, fileSHA256: pkg.digest,
                                detail: CaseOutputError.writtenContentDiffers(problem).errorDescription)
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
        /// S11 — optional, so a pending record kept by an older build still decodes.
        var manifestJSON: String? = nil, revisionFence: String? = nil, approvalID: String? = nil
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
        var pending = PendingRecord(id: UUID(), caseID: caseID, kind: pkg.kind.rawValue, route: pkg.route.rawValue, snapshotSHA256: pkg.digest,
                                    fileName: fileName, fileSHA256: fileSHA256, status: status.rawValue, detail: detail, releasedBy: pkg.actor,
                                    releasedAt: Date(), logDetail: logDetail)
        pending.manifestJSON = pkg.manifest?.json
        pending.revisionFence = pkg.manifest?.revisionFence
        pending.approvalID = pkg.approvalID?.uuidString
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
                INSERT OR IGNORE INTO case_document_outputs (id, case_id, kind, route, snapshot_sha256, file_name, file_sha256, status, detail, released_by, released_at,
                                                             manifest_json, revision_fence, approval_id)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(r.id), .uuid(r.caseID), .text(r.kind), .text(r.route), .text(r.snapshotSHA256), .optionalText(r.fileName), .optionalText(r.fileSHA256),
                      .text(r.status), .optionalText(r.detail), .text(r.releasedBy), .date(r.releasedAt),
                      .optionalText(r.manifestJSON), .optionalText(r.revisionFence), .optionalText(r.approvalID)])
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
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
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

// MARK: - The service side

extension CaseOutputService {

    /// The case log entries outputs and approvals write: they record what left, they do not change the case.
    private static let outputActions = ["exported", "exportRefused", "exportFailed", "outputApproved", "outputApprovalWithdrawn"]

    /// S11 (OUTPUT-02 / OUTPUT-08) — the case's revision for outputs: the map's revision fence without the outputs' own log
    /// entries and without WHEN items were last re-verified (each export re-verifies), plus every verification STATE. Two
    /// reads of the same fence saw the same case.
    fileprivate static func outputFence(_ db: isolated Database, caseID: UUID) throws -> String {
        var text = try CaseMapRepository.fence(db, caseID: caseID, ignoringActions: outputActions, verificationTimes: false)
        let parts: [(String, String)] = [("case_journal", "case_id = ?"), ("case_report_items", "case_id = ?"),
                                         ("case_allegation_evidence", "allegation_id IN (SELECT id FROM case_allegations WHERE case_id = ?)")]
        for (table, filter) in parts {
            let rows = try db.query("SELECT id, coalesce(verification, '') FROM \(table) WHERE \(filter) ORDER BY id;", [.uuid(caseID)])
            text += "|" + rows.map { "\($0.string(0) ?? ""):\($0.string(1) ?? "")" }.joined(separator: ",")
        }
        return CaseFileHash.sha256(text)
    }

    private func outputFence(caseID: UUID) async throws -> String {
        try await database.withSavepoint("co_fence_\(UUID().uuidString.prefix(8))") { db in try Self.outputFence(db, caseID: caseID) }
    }

    private static func stamp(_ d: Date) -> String { ISO8601DateFormatter.string(from: d, timeZone: .gmt, formatOptions: [.withInternetDateTime]) }

    /// The line every conclusion output carries: the approval of exactly this revision, or DRAFT with the revision.
    private func conclusionStamp(caseID: UUID, kind: CaseOutputKind, fence: String) async throws -> (line: String, approvalID: UUID?) {
        let active = try await approvalsRead(caseID: caseID).filter { $0.kind == kind && $0.isActive }
        let rev = String(fence.prefix(12))
        if let a = active.first(where: { $0.revisionFence == fence }) {
            return ("> APPROVED for release — approval \(a.id.uuidString.prefix(8)) by \(a.approvedBy) on \(Self.stamp(a.approvedAt))"
                    + (a.selfReview ? " (self-approved: the case is worked alone)" : "") + "; it covers case revision \(rev) exactly.\n\n", a.id)
        }
        if let earlier = active.first {
            return ("> DRAFT — not approved. An approval exists for an earlier revision of the case (\(earlier.revisionFence.prefix(12))); the case has changed since, so it does not cover this output. Case revision \(rev), read \(Self.stamp(Date())).\n\n", nil)
        }
        return ("> Case revision \(rev), read \(Self.stamp(Date())). Not approved: a draft until a reviewer approves this revision.\n\n", nil)
    }

    /// The release-time check for conclusion outputs (called by authorizeRelease).
    private func requireCurrentRevision(_ pkg: CaseOutputPackage) async throws {
        guard pkg.kind.presentsConclusions, let caseID = pkg.caseID, let m = pkg.manifest else { return }
        if let a = pkg.approvalID {
            guard let row = try await approvalsRead(caseID: caseID).first(where: { $0.id == a }), row.isActive else {
                throw CaseOutputError.approvalNoLongerCurrent("the approval this output was prepared under was withdrawn.")
            }
        }
        guard try await outputFence(caseID: caseID) == m.revisionFence else {
            if pkg.approvalID != nil { throw CaseOutputError.approvalNoLongerCurrent("the case changed after it was approved, so the approval no longer covers it.") }
            throw CaseOutputError.changedSincePrepared
        }
    }

    // MARK: Approvals

    private func approvalsRead(caseID: UUID) async throws -> [CaseOutputApproval] {
        try await database.query("""
            SELECT id, case_id, kind, revision_fence, approved_by, approved_at, note, self_review, withdrawn_at, withdrawn_reason
            FROM case_output_approvals WHERE case_id = ? ORDER BY approved_at DESC, rowid DESC;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let kind = r.string(2).flatMap(CaseOutputKind.init(rawValue:)), let fence = r.string(3),
                  let by = r.string(4), let at = r.date(5) else { return nil }
            return CaseOutputApproval(id: id, caseID: c, kind: kind, revisionFence: fence, approvedBy: by, approvedAt: at, note: r.string(6),
                                      selfReview: (r.int(7) ?? 0) == 1, withdrawnAt: r.date(8), withdrawnReason: r.string(9))
        }
    }

    /// The case's output approvals, newest first.
    public func approvals(caseID: UUID) async throws -> [CaseOutputApproval] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await approvalsRead(caseID: caseID)
    }

    /// OUTPUT-08 — approve `kinds` of output of the case AS IT IS NOW (its revision fence). Needs the review role in a team
    /// case; in a solo case the approval is labelled self-approved. A change to the case between reading the fence and
    /// recording the approval refuses it (a validated revision fence).
    @discardableResult
    public func approve(caseID: UUID, kinds: [CaseOutputKind], note: String?, actor: String, at date: Date = Date()) async throws -> [CaseOutputApproval] {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .review)
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseOutputError.approvalRefused("the approval needs your name.") }
        let chosen = kinds.filter(\.presentsConclusions)
        guard !chosen.isEmpty else { throw CaseOutputError.approvalRefused("only outputs that present conclusions (reports, the package, briefings, the money report) are approved.") }
        let fence = try await outputFence(caseID: caseID)
        let clean = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        var ids: [UUID] = []
        for kind in chosen {
            let id = UUID()
            ids.append(id)
            try await caseFiles.file.write("co_appr", caseID: caseID, actor: who, action: "outputApproved",
                                           detail: "\(kind.rawValue) · revision \(fence.prefix(12))", at: date, allowedWhenClosed: true) { db in
                guard try Self.outputFence(db, caseID: caseID) == fence else { throw CaseOutputError.changedSincePrepared }
                let solo = try !CaseAccessPolicy.isTeamCase(db, caseID: caseID)
                try db.exec("""
                    INSERT INTO case_output_approvals (id, case_id, kind, revision_fence, approved_by, approved_at, note, self_review)
                    VALUES (?,?,?,?,?,?,?,?);
                    """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .text(fence), .text(who), .date(date),
                          (clean?.isEmpty == false) ? .text(clean ?? "") : .null, .integer(solo ? 1 : 0)])
            }
        }
        return try await approvalsRead(caseID: caseID).filter { ids.contains($0.id) }
    }

    /// Withdraw an approval with a reason (it stays in the record).
    public func withdrawApproval(caseID: UUID, approvalID: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .review)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw CaseOutputError.approvalRefused("withdrawing an approval needs a reason.") }
        try await caseFiles.file.write("co_apprw", caseID: caseID, actor: actor, action: "outputApprovalWithdrawn", detail: why, at: date, allowedWhenClosed: true) { db in
            guard let r = try db.query("SELECT withdrawn_at FROM case_output_approvals WHERE id = ? AND case_id = ?;", [.uuid(approvalID), .uuid(caseID)]).first else {
                throw CaseOutputError.approvalRefused("that approval is not in this case.")
            }
            guard r.isNull(0) else { throw CaseOutputError.approvalRefused("that approval was already withdrawn.") }
            try db.exec("UPDATE case_output_approvals SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;",
                        [.text(actor), .date(date), .text(why), .uuid(approvalID)])
        }
    }

    // MARK: Products

    /// Freeze `read` under one revision: the output fence before and after must match (three tries).
    private func frozen<T: Sendable>(caseID: UUID, _ read: () async throws -> T) async throws -> (value: T, fence: String) {
        for _ in 1...3 {
            let before = try await outputFence(caseID: caseID)
            let value = try await read()
            if let hook = hooks.duringFreeze { await hook() }
            if try await outputFence(caseID: caseID) == before { return (value, before) }
        }
        throw CaseOutputError.keptChanging
    }

    /// A text product of the case: frozen under one revision, stamped (approval or DRAFT + revision), protected, revalidated.
    private func prepareConclusionText(caseID: UUID, kind: CaseOutputKind, route: CaseOutputRoute, actor: String, selection: String,
                               counts: [String: Int], citations: [StudioEvidenceRef], read: () async throws -> String) async throws -> CaseOutputPackage {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let body: String, fence: String, stamp: (line: String, approvalID: UUID?)
        do {
            guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
            try await requireExport(caseID: caseID, actor: actor)
            (body, fence) = try await frozen(caseID: caseID, read)
            stamp = try await conclusionStamp(caseID: caseID, kind: kind, fence: fence)
        } catch {
            await recordRefusal(caseID: caseID, kind: kind, route: route, actor: actor, error)
            throw error
        }
        let base = try await prepareText(caseID: caseID, kind: kind, route: route, actor: actor, citations: citations, text: stamp.line + body)
        var pkg = CaseOutputPackage(id: base.id, caseID: caseID, kind: kind, route: route, text: base.text, data: base.data, digest: base.digest,
                                    scopeFingerprint: base.scopeFingerprint, approved: stamp.approvalID != nil, custodyIncomplete: false, actor: actor,
                                    preparedAt: base.preparedAt, citations: base.citations)
        pkg.approvalID = stamp.approvalID
        pkg.manifest = CaseOutputManifest(caseID: caseID, kind: kind, revisionFence: fence, scopeFingerprint: base.scopeFingerprint, readAt: base.preparedAt,
                                          selection: selection, format: "text", counts: counts, pinned: [:],
                                          sourceVersions: Set(citations.compactMap(\.sourceVersionID)).map(\.uuidString).sorted(), omitted: [:],
                                          approval: stamp.approvalID?.uuidString, state: stamp.approvalID == nil ? "draft" : "approved")
        return pkg
    }

    /// The person must be allowed to export from the case before anything of it is read for an output; a refusal is recorded.
    private func requireExport(caseID: UUID, actor: String, recording kind: CaseOutputKind, route: CaseOutputRoute) async throws {
        do { try await requireExport(caseID: caseID, actor: actor) } catch {
            await recordRefusal(caseID: caseID, kind: kind, route: route, actor: actor, error)
            throw error
        }
    }

    /// OUTPUT-01 — the review case's own record (HISTORY-08) through the release check: the person must still be allowed to
    /// export from the review case, the original's records are re-read through the reference (re-checked), protected names
    /// are scrubbed, and the release is recorded.
    public func prepareReviewRecord(caseID: UUID, review: CaseHistoryReviewService, route: CaseOutputRoute = .file, actor: String) async throws -> CaseOutputPackage {
        try await requireExport(caseID: caseID, actor: actor, recording: .reviewRecord, route: route)
        let findings = try await caseFiles.file.reviewFindings(caseID: caseID).filter(\.isActive).count
        return try await prepareConclusionText(caseID: caseID, kind: .reviewRecord, route: route, actor: actor, selection: "The review case's own record",
                                               counts: ["reviewFindings": findings], citations: []) {
            try await review.reviewExport(caseID: caseID)
        }
    }

    /// OUTPUT-01 — the case's money report (the same text the report and the package carry), every cited statement or
    /// document re-checked against the export policy.
    public func prepareMoneyReport(caseID: UUID, route: CaseOutputRoute = .file, actor: String) async throws -> CaseOutputPackage {
        try await requireExport(caseID: caseID, actor: actor, recording: .moneyReport, route: route)
        let ledger = try await caseFiles.file.moneyLedger(caseID: caseID)
        let cites = ledger.records.filter { $0.withdrawnAt == nil }.compactMap { r in r.sourceVersionID.map { StudioEvidenceRef(sourceVersionID: $0, quote: r.quote) } }
        let title = try await caseFiles.caseHeader(caseID)?.title ?? "Case"
        return try await prepareConclusionText(caseID: caseID, kind: .moneyReport, route: route, actor: actor, selection: "The case's money records",
                                               counts: ["moneyRecords": ledger.records.filter { $0.withdrawnAt == nil }.count], citations: cites) {
            "# Money — \(title)\n\n" + CaseMoneyReport.markdown(try await self.caseFiles.file.moneyLedger(caseID: caseID))
        }
    }

    /// OUTPUT-01 — a briefing: a frozen one as recorded, a live one resolved against the case now (saying what changed).
    public func prepareBriefing(caseID: UUID, briefingID: UUID, route: CaseOutputRoute = .file, actor: String,
                                load: @escaping @Sendable (UUID) async -> CaseMapLoad) async throws -> CaseOutputPackage {
        try await requireExport(caseID: caseID, actor: actor, recording: .briefing, route: route)
        guard let b = try await caseFiles.file.briefLedger(caseID: caseID).briefings.first(where: { $0.id == briefingID }) else {
            throw CaseBriefError.notFound("briefing")
        }
        let projection = b.isFrozen ? nil : await load(caseID).projection
        let cites = (b.activeItems.compactMap(\.record).compactMap { projection?.node($0) }.flatMap(\.sources))
            .compactMap { s in s.sourceVersionID.map { StudioEvidenceRef(sourceVersionID: $0, objectID: s.objectID, quote: s.quote) } }
        let steps = CaseBriefings.steps(b, in: projection, viewName: { _ in nil })
        return try await prepareConclusionText(caseID: caseID, kind: .briefing, route: route, actor: actor, selection: "Briefing “\(b.title)”",
                                               counts: ["steps": steps.count], citations: cites) {
            var out = "# Briefing — \(b.title)\n\n"
            if let p = b.purpose { out += "Purpose: \(p)\n\n" }
            out += b.isFrozen ? "Frozen by \(b.frozenBy ?? "") on \(b.frozenAt.map(Self.stamp) ?? ""): the steps as they were recorded then.\n\n"
                              : "Live: each step as the case is now, with what changed since it was added.\n\n"
            if !b.isActive { out += "_This briefing was withdrawn (\(b.withdrawnReason ?? "")); it is shown as recorded._\n\n" }
            for (i, s) in steps.enumerated() {
                out += "\(i + 1). \(s.title)" + (s.state.isEmpty ? "" : " — \(s.state)") + (s.change.map { " (\($0))" } ?? "") + "\n"
            }
            return out
        }
    }

    /// OUTPUT-03..05 — the portable read-only case package for `selection`, frozen under one revision (the map, the money
    /// report and the briefings read between two equal fences), protected, revalidated and checked for active content.
    public func preparePackage(caseID: UUID, selection: CasePackageSelection, actor: String,
                               load: @escaping @Sendable (UUID) async -> CaseMapLoad) async throws -> CaseOutputPackage {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let html: String, content: CasePackageContent, fence: String, stamp: (line: String, approvalID: UUID?), manifest: CaseOutputManifest
        do {
            guard try await caseFiles.caseHeader(caseID) != nil else { throw CaseOutputError.caseGone }
            try await requireExport(caseID: caseID, actor: actor)
            let read: (CaseMapProjection, String, [CaseBriefing]), f: String
            (read, f) = try await frozen(caseID: caseID) {
                let mapLoad = await load(caseID)
                guard let p = mapLoad.projection else {
                    if case .failed(let why) = mapLoad.state { throw CaseOutputError.writeFailed("the case map could not be read (\(why))") }
                    throw CaseOutputError.caseGone
                }
                let money = CaseMoneyReport.markdown(try await self.caseFiles.file.moneyLedger(caseID: caseID))
                let briefs = try await self.caseFiles.file.briefLedger(caseID: caseID).briefings
                return (p, money, briefs)
            }
            fence = f
            let (projection, money, briefings) = read
            if case .briefing(let id) = selection, !briefings.contains(where: { $0.id == id }) { throw CaseBriefError.notFound("briefing") }
            stamp = try await conclusionStamp(caseID: caseID, kind: .casePackage, fence: fence)
            let header = [selection.label + ".", "Read at \(Self.stamp(Date())); case revision \(fence.prefix(12))."]
                + (try await currentHoldLines(caseID: caseID))
                + ["Protected source identities are removed from this package, as from every export.",
                   "Every cited source was re-checked against this case's export policy at the moment of release."]
            let raw = CasePortablePackage.build(projection: projection, selection: selection, briefings: briefings, money: money, header: header)
            guard !raw.items.isEmpty else { throw CaseOutputError.emptyContent }
            let names = try await protectedNames()
            var cache: [String: String] = [:]
            content = try raw.mapped { text in
                if let hit = cache[text] { return hit }
                let scrubbed = ProtectedIdentities.scrub(SecretRedactor.redact(text), names: names)
                guard scrubbed.leaks.isEmpty else { throw CaseOutputError.protectedIdentityLeak(scrubbed.leaks.count) }
                cache[text] = scrubbed.text
                return scrubbed.text
            }
            let selectionText: String
            switch selection {
            case .wholeCase: selectionText = "wholeCase"
            case .branch(let r): selectionText = "branch:\(r.key)"
            case .briefing(let id): selectionText = "briefing:\(id.uuidString)"
            case .records(let r): selectionText = "records:" + r.map(\.key).sorted().joined(separator: ",")
            }
            manifest = CaseOutputManifest(caseID: caseID, kind: .casePackage, revisionFence: fence, scopeFingerprint: nil, readAt: Date(),
                                          selection: selectionText, format: "html", counts: content.counts, pinned: content.pinned,
                                          sourceVersions: Set(content.citations.compactMap(\.sourceVersionID)).map(\.uuidString).sorted(),
                                          omitted: content.omitted, approval: stamp.approvalID?.uuidString, state: stamp.approvalID == nil ? "draft" : "approved")
            guard let json = manifest.json else { throw CaseOutputError.writeFailed("the manifest could not be written") }
            html = CasePortablePackage.html(content, status: stamp.line.replacingOccurrences(of: "> ", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
                                            manifestJSON: json)
            if let v = CasePortablePackageReader.read(html).violations.first { throw CaseOutputError.unsafePackage(v) }
        } catch {
            await recordRefusal(caseID: caseID, kind: .casePackage, route: .file, actor: actor, error)
            throw error
        }
        let base = try await prepareData(caseID: caseID, kind: .casePackage, route: .file, actor: actor, citations: content.citations,
                                         texts: content.texts, data: Data(html.utf8))
        var pkg = CaseOutputPackage(id: base.id, caseID: caseID, kind: .casePackage, route: .file, text: html, data: base.data, digest: base.digest,
                                    scopeFingerprint: base.scopeFingerprint, approved: stamp.approvalID != nil, custodyIncomplete: false, actor: actor,
                                    preparedAt: base.preparedAt, citations: base.citations)
        pkg.approvalID = stamp.approvalID
        var m = manifest
        m.scopeFingerprint = base.scopeFingerprint
        pkg.manifest = m
        return pkg
    }

    // MARK: Routes with their own writer (OUTPUT-01)

    /// OUTPUT-01 — a route whose own writer puts the bytes out (a persona studio's file exporter, copy and print preview)
    /// still leaves through this door: prepared here (`prepareText`), authorised here immediately before the bytes leave
    /// (role, case, sources, protected names; a refusal is recorded and nothing may leave), and recorded here afterwards
    /// (`recordExternalRelease`).
    public func authorizeExternalRelease(_ pkg: CaseOutputPackage) async throws {
        do { try await authorizeRelease(pkg) } catch {
            if let caseID = pkg.caseID { await recordRefusal(caseID: caseID, kind: pkg.kind, route: pkg.route, actor: pkg.actor, error) }
            throw error
        }
    }

    /// Record what such a writer released. A file is read back and must hold exactly the released bytes (otherwise it is
    /// recorded as failed, never as an export); a copy or print records the digest of the released text.
    public func recordExternalRelease(_ pkg: CaseOutputPackage, route: CaseOutputRoute, writtenTo url: URL?) async -> CaseOutputReceipt {
        var released = CaseOutputPackage(id: pkg.id, caseID: pkg.caseID, kind: pkg.kind, route: route, text: pkg.text, data: pkg.data, digest: pkg.digest,
                                         scopeFingerprint: pkg.scopeFingerprint, approved: pkg.approved, custodyIncomplete: pkg.custodyIncomplete,
                                         actor: pkg.actor, preparedAt: pkg.preparedAt, citations: pkg.citations)
        released.manifest = pkg.manifest
        released.approvalID = pkg.approvalID
        guard let url else {
            return await record(released, status: .released, fileName: nil, fileSHA256: nil,
                                detail: "\(route.rawValue): digest of the released text, not of the \(route == .print ? "printer's" : "recipient's") bytes")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let written: Data
        do { written = try Data(contentsOf: url) } catch {
            KalsmritikoshLog.app.error("Case output read-back failed: \(error.localizedDescription, privacy: .public)")
            return await record(released, status: .failed, fileName: url.lastPathComponent, fileSHA256: nil,
                                detail: CaseOutputError.writeFailed(error.localizedDescription).errorDescription)
        }
        let sha = StudioRecordRepository.sha256(written)
        guard sha == released.digest else {
            return await record(released, status: .failed, fileName: url.lastPathComponent, fileSHA256: sha, detail: CaseOutputError.writtenBytesDiffer.errorDescription)
        }
        return await record(released, status: .written, fileName: url.lastPathComponent, fileSHA256: sha, detail: nil)
    }

    /// OUTPUT-07 — a map export carries a manifest too (items and links frozen), so its written file is reconciled.
    private func mapManifest(_ request: CaseMapExportRequest, frozen: CaseMapExportFrozen, format: CaseMapExportFormat, route: CaseOutputRoute,
                     scopeFingerprint: String?) async throws -> CaseOutputManifest {
        let caseID = request.projection.caseID
        let fence = try await outputFence(caseID: caseID)
        var pinned: [String: String] = [:]
        for id in request.shown { if let n = request.projection.node(id) { pinned[n.id.key] = n.revision ?? "" } }
        let fmt = route == .file ? format.rawValue : "csv"
        return CaseOutputManifest(caseID: caseID, kind: .caseMap, revisionFence: fence, scopeFingerprint: scopeFingerprint, readAt: Date(),
                                  selection: "Map view “\(request.viewTitle)”", format: fmt,
                                  counts: ["items": frozen.items.count, "links": frozen.relations.count], pinned: pinned,
                                  sourceVersions: Set(frozen.citations.compactMap(\.sourceVersionID)).map(\.uuidString).sorted(),
                                  omitted: ["notShown": max(0, request.projection.nodes.count - frozen.items.count)], approval: nil, state: "record")
    }
}
