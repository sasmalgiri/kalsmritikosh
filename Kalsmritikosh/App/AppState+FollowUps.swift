//
//  AppState+FollowUps.swift
//  Kalsmritikosh
//
//  Unified path SEARCH-16 (owner 2026-11-22) — not tested yet. Gathers what FollowUpSuggester needs
//  from the ledger: the cited documents' people, organisations and dated events, and on the case path
//  the briefing's open items (contradictions among the cited documents, documents not read, missing
//  evidence). Read-only; no model call.
//

import Foundation
import os

extension AppState {

    func followUpSuggestions(question: String, answer: VerifiedAnswer, caseID: UUID?) async -> [String] {
        var input = FollowUpSuggester.Input(question: question)
        let objectIDs = Array(Set(answer.citations.map(\.objectID))).sorted { $0.uuidString < $1.uuidString }.prefix(8)
        if let entities {
            var people: [String] = [], orgs: [String] = []
            for id in objectIDs {
                do {
                    for e in try await entities.findByMentionSource(id) {
                        switch e.kind {
                        case .person where !people.contains(e.value): people.append(e.value)
                        case .organization where !orgs.contains(e.value), .vendor where !orgs.contains(e.value): orgs.append(e.value)
                        default: break
                        }
                    }
                } catch {
                    KalsmritikoshLog.brain.error("Follow-ups: entities unreadable: \(String(describing: error), privacy: .public)")
                }
                if people.count >= 4 && orgs.count >= 2 { break }
            }
            input.people = people; input.organisations = orgs
        }
        if let events {
            for id in objectIDs.prefix(4) {
                do {
                    let found = try await events.findBySourceObject(id).sorted { $0.date < $1.date }
                    input.events += found.prefix(2).map(\.title)
                } catch {
                    KalsmritikoshLog.brain.error("Follow-ups: events unreadable: \(String(describing: error), privacy: .public)")
                }
            }
        }
        if let caseID {
            if let readout = await caseCoverage(caseID: caseID) {
                input.unreadDocuments = readout.entries.filter { $0.status != .read }.map(\.name)
            }
            if let db = database, !objectIDs.isEmpty {
                do {
                    let material = try await CaseBriefingRepository(database: db)
                        .material(objectIDs: Array(objectIDs), versionToObject: [:])
                    input.conflicts = material.contradictions.map(\.description)
                } catch {
                    KalsmritikoshLog.brain.error("Follow-ups: case briefing unavailable: \(String(describing: error), privacy: .public)")
                }
            }
            // Missing evidence: the answer's own unmet obligations, when the brain recorded them.
            if answer.refused || answer.answerState == .notFound {
                input.missingEvidence = [String(question.prefix(60))]
            }
        }
        return FollowUpSuggester.suggestions(input)
    }
}
