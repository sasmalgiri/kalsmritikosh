//
//  CaseSearchLive.swift
//  Kalsmritikosh
//
//  Living case map M5 — the live sources of a case evidence search: the case's scope through the ONE
//  case→version resolver (CaseRetrievalScopeResolver, fail-closed), the sources the case excluded (named in
//  the receipt), Package B's reading coverage, and the coverage labels. Reads the ledger only.
//
//  Also the hand-off of a search hit to the case report (`PassageReportSelection`): the passage is
//  verified through the case's evidence verifier, as `PassageChronology` does for the chronology, and goes
//  through `CaseFileRepository.addReportItem`, which refuses a source outside the case.
//

import Foundation
import os

extension CaseSearchSources {
    public static func live(database: Database) -> CaseSearchSources {
        let cases = InvestigationCaseRepository(database: database)
        let resolver = CaseRetrievalScopeResolver(evidence: EvidenceStore(database: database))
        let coverageRepo = CaseCoverageRepository(database: database)
        return CaseSearchSources(
            scope: { caseID in
                guard let record = try await cases.fetch(caseID: caseID) else { throw CaseSearchServiceError.failed("The case was not found.") }
                let scope = try await resolver.scope(for: record)
                let fingerprint = CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: record.caseHeader.revision, scope: scope).value
                var excluded: [String] = []
                let versionRefs = record.sources.filter { !$0.inScope }.compactMap { UUID(uuidString: $0.sourceRef) }
                let labels = try await coverageRepo.labels(for: versionRefs)
                for s in record.sources where !s.inScope {
                    if let id = UUID(uuidString: s.sourceRef), let name = labels[id] { excluded.append(name); continue }
                    if let id = UUID(uuidString: s.sourceRef),
                       let row = try await database.query("SELECT url FROM files WHERE id = ?;", [.uuid(id)]).first, let url = row.string(0) {
                        let u = URL(string: url) ?? URL(fileURLWithPath: url)
                        excluded.append(u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent)
                        continue
                    }
                    excluded.append("Source \(s.sourceRef.prefix(8))")
                }
                return CaseSearchScope(caseID: caseID, versionIDs: scope.authorizedSourceVersionIDs, excludedNames: excluded, fingerprint: fingerprint)
            },
            coverage: { caseID, versions in
                do {
                    guard let record = try await cases.fetch(caseID: caseID) else { return nil }
                    return try await CaseCoverageReadout.load(database: database, workspaceID: record.caseHeader.workspaceID, scope: versions)
                } catch {
                    KalsmritikoshLog.app.error("Case search coverage unavailable: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            },
            labels: { ids in
                do { return try await coverageRepo.labels(for: ids) } catch {
                    KalsmritikoshLog.app.error("Case search labels unavailable: \(error.localizedDescription, privacy: .public)")
                    return [:]
                }
            },
            repository: CaseSearchRepository(database: database))
    }
}

/// "Select for report" from a search hit: the matched passage becomes an included report item of the case,
/// with its citation verified the same way the case file verifies every citation.
public nonisolated enum PassageReportSelection {
    @discardableResult
    public static func add(caseID: UUID, objectID: UUID, sourceVersionID: UUID? = nil, quote: String, text: String,
                           caseFiles: CaseFileService, actor: String, at date: Date = Date()) async throws -> (itemID: UUID, support: CaseEvidenceSupport) {
        try PaidUse.require("edit the case file")
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { throw PassageChronologyError.emptyPassage }
        var version = sourceVersionID
        if version == nil { version = try await caseFiles.file.sourceVersionToCite(objectID: objectID, caseID: caseID) }
        guard let version else { throw PassageChronologyError.noSourceVersion }
        let asked = StudioEvidenceRef(sourceVersionID: version, quote: quote)
        let verification = await caseFiles.verify(reference: version.uuidString, passage: asked, caseID: caseID)
        var citation = verification.passage ?? asked
        if citation.objectID == nil { citation.objectID = objectID }
        let origin = "search:" + PassageChronology.origin(caseID: caseID, sourceVersionID: version, blockID: citation.blockID, quote: quote)
        do {
            let id = try await caseFiles.file.addReportItem(caseID: caseID, allegationID: nil, text: text, quote: quote, evidenceRef: version.uuidString,
                                                            origin: origin, citations: [citation], support: verification.support, actor: actor, at: date)
            return (id, verification.support)
        } catch CaseFileError.alreadyCarried(_) {
            KalsmritikoshLog.app.info("Search hit to report refused: already selected")
            throw PassageReportSelectionError.alreadySelected
        } catch CaseFileError.unresolvedReference(_, let why) {
            KalsmritikoshLog.app.info("Search hit to report refused: \(why, privacy: .public)")
            throw PassageChronologyError.outOfScope(why)
        }
    }
}

public nonisolated enum PassageReportSelectionError: Error, Equatable, LocalizedError {
    case alreadySelected
    public var errorDescription: String? {
        "This passage is already selected for the report. Nothing was added; change it in the case's Log & exports."
    }
}
