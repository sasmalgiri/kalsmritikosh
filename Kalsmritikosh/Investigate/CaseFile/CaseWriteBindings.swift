//
//  CaseWriteBindings.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (CHANGE-11, ACTION-08, ACTION-13) — records written from the map are bound to the exact inputs
//  they rest on when they are written, so a later change to an input marks them for review (and only them):
//  • an action's result version, naming what was examined (source versions of the case, case records) — optionally with
//    a result report whose points follow — bound to the action and the documents examined;
//  • an evidence request raised from a report point, bound to that point.
//  The write and the binding are two steps; a binding that cannot be made is logged and said, never hidden, and the
//  record stays written (a stale flag that cannot be raised is reported, the record is not rolled back).
//

import Foundation
import os

public nonisolated struct CaseBoundWrite<T: Sendable>: Sendable {
    public let value: T
    /// nil: bound. Otherwise why the binding could not be made (the record itself was written).
    public let bindingProblem: String?
}

extension CaseFileService {

    /// The map keys of the inputs a result names: the action itself, the documents whose versions were examined (as the map
    /// shows them now), and the case records named.
    nonisolated static func resultInputKeys(caseID: UUID, taskID: UUID, inputs: [CaseExaminedInput], projection p: CaseMapProjection) -> [String] {
        var keys = [CaseMapNodeID(caseID: caseID, kind: .task, id: taskID).key]
        for i in inputs {
            switch i.kind {
            case "sourceVersion":
                guard let v = UUID(uuidString: i.id) else { continue }
                if let doc = p.nodes.first(where: { $0.id.kind == .document && $0.sources.contains { $0.sourceVersionID == v } }) { keys.append(doc.id.key) }
            case "allegation": keys.append(CaseMapNodeID(caseID: caseID, kind: .allegation, recordID: i.id).key)
            case "point": keys.append(CaseMapNodeID(caseID: caseID, kind: .reportPoint, recordID: i.id).key)
            case "report": keys.append(CaseMapNodeID(caseID: caseID, kind: .report, recordID: i.id).key)
            case "request": keys.append(CaseMapNodeID(caseID: caseID, kind: .request, recordID: i.id).key)
            default: continue
            }
        }
        let onMap = Set(p.nodes.map(\.id.key))
        var seen = Set<String>()
        return keys.filter { onMap.contains($0) && seen.insert($0).inserted }
    }

    /// Record a result version of an action (and, when `reportTitle` is given, the result report its points follow), then
    /// bind it to the action and what it examined.
    @discardableResult
    public func recordBoundResult(caseID: UUID, taskID: UUID, kind: CaseResultKind, outcome: CaseResultOutcomeKind, summary: String,
                                  inputs: [CaseExaminedInput], reportTitle: String?, projection: CaseMapProjection, actor: String,
                                  at date: Date = Date()) async throws -> CaseBoundWrite<CaseActionResult> {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        var reportID: UUID?
        if let t = reportTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            reportID = try await recordResult(caseID: caseID, taskID: taskID, title: t, actor: actor, at: date)
        }
        let result = try await file.recordActionResult(caseID: caseID, taskID: taskID, kind: kind, outcome: outcome, summary: summary, reportID: reportID,
                                                       inputs: inputs, actor: actor, at: date)
        let keys = Self.resultInputKeys(caseID: caseID, taskID: taskID, inputs: inputs, projection: projection)
        do {
            _ = try await file.bindDerivation(caseID: caseID, derived: .actionResult, derivedID: result.id.uuidString,
                                              label: "Result \(result.revision) of an action", inputs: keys, projection: projection, actor: actor, at: date)
            return CaseBoundWrite(value: result, bindingProblem: nil)
        } catch {
            KalsmritikoshLog.app.error("Result not bound to its inputs: \(error.localizedDescription, privacy: .public)")
            return CaseBoundWrite(value: result, bindingProblem: "The result is recorded, but it could not be tied to its inputs (\(error.localizedDescription)); a later change to them will not mark it for review.")
        }
    }

    /// An evidence request raised from a report point, bound to that point.
    @discardableResult
    public func requestEvidenceBound(caseID: UUID, fromPoint pointID: UUID, details: EvidenceRequestDetails, purpose: String,
                                     analysis: InvestigationAnalysisService, projection: CaseMapProjection, actor: String,
                                     at date: Date = Date()) async throws -> CaseBoundWrite<UUID> {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let id = try await requestEvidence(caseID: caseID, fromPoint: pointID, details: details, purpose: purpose, analysis: analysis, actor: actor, at: date)
        do {
            _ = try await file.bindDerivation(caseID: caseID, derived: .request, derivedID: id.uuidString, label: "Evidence request: \(details.description.prefix(60))",
                                              inputs: [CaseMapNodeID(caseID: caseID, kind: .reportPoint, id: pointID).key], projection: projection, actor: actor, at: date)
            return CaseBoundWrite(value: id, bindingProblem: nil)
        } catch {
            KalsmritikoshLog.app.error("Request not bound to its point: \(error.localizedDescription, privacy: .public)")
            return CaseBoundWrite(value: id, bindingProblem: "The request is recorded, but it could not be tied to its point (\(error.localizedDescription)).")
        }
    }
}
