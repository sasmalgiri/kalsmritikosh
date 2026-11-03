//
//  AppState+CaseRoles.swift
//  Kalsmritikosh
//
//  P4 (real-case evaluation 2026-11-03, D5) — before a case's findings are built, the role each person
//  with proceeding steps holds in the case's documents is read by the person's cloud reader (Online,
//  AI on, document reading on). The rules already gave officials no steps (ProceedingRoleClassifier);
//  this pass catches what the rules read as a defendant but a verified quote shows to be an official
//  ("U.S. District Judge John Michael Vazquez"): that person's step claims from that document are
//  rejected through the claim review log — append-only, with the reviewer, the role and the quote
//  recorded, restorable by a later review — so they leave the findings. Nothing is deleted.
//
//  Only cleared documents are read (CloudSourceGate, bound to the case's scope). No reader, no
//  clearance, or a reading that does not verify: nothing changes.
//

import Foundation
import OSLog

extension AppState {
    static let caseRoleDocumentCap = 40

    /// The pre-findings role pass (InvestigationFindingsService `prepare`).
    nonisolated static func caseRolePass(objects: KnowledgeObjectRepository, sensitiveScopes: SensitiveScopeRepository,
                                         claims: ClaimRepository, reviews: ClaimReviewRepository,
                                         answers: InvestigationAnswerService?, readers: CloudReaderHolder)
        -> @Sendable (UUID, Set<UUID>) async -> Void {
        { caseID, versions in
            let current = readers.current
            guard current.modelsAllowedOverride ?? FeatureFlags.aiRegimeValue().allowsAI,
                  let reader = current.roleReader else { return }
            do {
                let byObject = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
                let ids = byObject.keys.sorted { $0.uuidString < $1.uuidString }.prefix(caseRoleDocumentCap)
                // The step claims each document carries, by the person they are about.
                var stepClaims: [UUID: [String: [Claim.ID]]] = [:]
                var texts: [UUID: String] = [:]
                for id in ids {
                    for claimID in try await claims.claimIDs(citingObject: id) {
                        guard let c = try await claims.claim(id: claimID), c.subjectID != nil,
                              c.derivedFrom.contains(where: { $0.kind == .event }),
                              c.statement.range(of: proceedingStepStatement, options: .regularExpression) != nil else { continue }
                        stepClaims[id, default: [:]][c.subjectLabel, default: []].append(claimID)
                    }
                    if stepClaims[id] != nil, let ko = try await objects.load(id: id) { texts[id] = ko.content }
                }
                guard !stepClaims.isEmpty else { return }
                let gate = CloudSourceGate(sensitiveScope: sensitiveScopes, objects: objects).bound(to: answers?.cloudScope(caseID: caseID))
                let (clearance, denied) = await gate.clear(Array(texts.keys), purpose: "Read the role of each person in the case's documents")
                if !denied.isEmpty { KalsmritikoshLog.brain.info("role reading: \(denied.count, privacy: .public) document(s) not cleared") }
                var passages: [VerifiedRoleReader.Passage] = []
                var people: [String] = []
                for (id, byPerson) in stepClaims.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                    guard let text = texts[id], clearance.clearedObjectIDs.contains(id) else { continue }
                    for person in byPerson.keys.sorted() {
                        let naming = VerifiedRoleReader.sentences(naming: person, in: text)
                        guard !naming.isEmpty else { continue }
                        passages.append(VerifiedRoleReader.Passage(objectID: id, text: naming))
                        people.append(person)
                    }
                }
                let readings = await reader.read(people: people, passages: passages, clearance: clearance)
                var rejected = 0
                for r in readings where r.role.takesNoSteps {
                    for claimID in stepClaims[r.objectID]?[r.person] ?? [] {
                        if let latest = try await reviews.latestReview(claimID: claimID), latest.reviewer == roleReviewer { continue }
                        try await reviews.record(ClaimReview(
                            claimID: claimID, disposition: .rejected, reviewer: roleReviewer,
                            reason: "\(r.person) is the \(r.role.label) in this document, not a defendant (\(r.provenance)): \u{201C}\(r.quote)\u{201D}",
                            reviewedAt: Date()))
                        rejected += 1
                    }
                }
                KalsmritikoshLog.brain.info("role reading: \(readings.count, privacy: .public) verified role(s); \(rejected, privacy: .public) step claim(s) of officials set aside")
            } catch {
                KalsmritikoshLog.brain.error("role reading failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The reviewer recorded on a role reading's claim review.
    static let roleReviewer = "Role reader (AI)"

    /// "Guy R. Miller pleaded guilty" — a proceeding step event's claim statement.
    static let proceedingStepStatement = #"\s(?:charged|arrested|arraigned|pleaded guilty|convicted|acquitted|sentenced|pardoned|released)\.?$"#
}
