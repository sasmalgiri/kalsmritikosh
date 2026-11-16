//
//  AppState+CaseMethodReview.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (REASON-14, MAP-13) — "What haven't we considered?" for one case: read the case's own records,
//  then review every registered method against them (CaseMethodReview, offline, no AI). A part of the case that cannot be
//  read is named as a problem, never counted as zero, so the review says what it could not see.
//

import Foundation
import os

extension AppState {

    /// The method review for a case, and the parts of the case that could not be read (each named). `question` overrides
    /// the case's own question (a point or passage the person is looking at).
    func caseMethodReview(caseID: UUID, question: String? = nil, now: Date = Date()) async -> (review: CaseMethodReviewResult?, problems: [String]) {
        guard let files = caseFiles, let custodyService = investigationCustody else {
            return (nil, ["The case file is not open yet."])
        }
        var problems: [String] = []
        func read<T>(_ what: String, _ body: () async throws -> T) async -> T? {
            do { return try await body() } catch {
                KalsmritikoshLog.app.error("Method review: \(what, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
                problems.append("\(what) could not be read (\(error.localizedDescription)); the review treats it as unknown.")
                return nil
            }
        }
        guard let custody = await read("The custody record", { try await custodyService.manifest(caseID: caseID) }),
              let snapshotOrNil = await read("The case file", { try await files.snapshot(caseID: caseID, custody: custody) }),
              let snapshot = snapshotOrNil else {
            return (nil, problems.isEmpty ? ["The case could not be read."] : problems)
        }
        let coverage = await caseCoverage(caseID: caseID)
        if coverage == nil { problems.append("Which documents are read could not be determined; unread documents are not counted.") }
        var openContradictions = 0
        if let desk = investigationContradictionGap,
           let items = await read("The contradictions", { try await desk.contradictionReviewItems(caseID: caseID) }) {
            openContradictions = items.filter { $0.status.awaitingReview }.count
        }
        let money = await read("The money records", { try await files.file.moneyLedger(caseID: caseID) })
        var hypotheses: [InvestigationHypothesis] = [], requests: [EvidenceRequestFile] = []
        if let analysis = investigationAnalysis {
            hypotheses = await read("The open explanations", { try await analysis.hypotheses(caseID: caseID) }) ?? []
            requests = await read("The evidence requests", { try await analysis.requestFiles(caseID: caseID) }) ?? []
        }
        var runs: [MethodRun] = []
        if let methods = investigationMethods {
            runs = await read("The case's method runs", { try await methods.runs(caseID: caseID) }) ?? []
        } else {
            problems.append("The method engine is not available; earlier method work is not reused.")
        }
        let asked = (question ?? snapshot.caseHeader.purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let input = CaseMethodReviewInput.from(question: asked, snapshot: snapshot, coverage: coverage, openContradictions: openContradictions,
                                               money: money, hypotheses: hypotheses, requests: requests, runs: runs, now: now)
        return (CaseMethodReview.assess(methods: CaseMethodReviewMethod.registered, input: input), problems)
    }
}
