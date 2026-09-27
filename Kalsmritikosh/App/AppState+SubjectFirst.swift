//
//  AppState+SubjectFirst.swift
//  Kalsmritikosh
//
//  L5 (2026-09-27) — SUBJECT FIRST. When a question names a subject (an
//  identifier, or a definite reference the anchor register resolves) and asks
//  where it stands or what happened in it, the answer comes from that
//  subject's OWN dated records — the anchors, and every document that names
//  them — before retrieval. On the owner's archive the general pipeline spent
//  minutes and answered "status of application 202331019665" with a filing-
//  form line while the grant milestone sat in the ledger.
//
//  Deterministic, cited, no model. Returns nil whenever it cannot answer
//  (no subject, no matching record) so the full pipeline still runs.
//

import Foundation
import OSLog

extension AppState {
    public func composeSubjectEventAnswer(question: String, access: SensitiveAccessContext) async -> VerifiedAnswer? {
        // Same fence as the story door: a narrowed access context is not yet
        // scope-enforced here, so it falls through to the scoped pipeline.
        guard access.scope.isGlobalOwnerBypass else { return nil }
        guard let entities, let events else { return nil }
        if let person = await composePersonAnswer(question: question) { return person }
        let shape = QuestionShapeRouter.route(question).shape
        let asksStatus = shape == .status
        let namesEvent = !EventAnswerComposer.vocabularyTerms(in: question).isEmpty
        // Counting/listing/yes-no shapes keep their own composers downstream.
        guard asksStatus || (namesEvent && shape == .unresolved) else { return nil }

        let anchors = (try? await entities.allAnchors()) ?? []
        let charter = SubjectResolver.resolve(question: question, anchors: anchors)
        guard !charter.anchors.isEmpty else { return nil }
        let subjectEvents = (try? await events.eventsForAnchors(charter.anchors.map(\.id))) ?? []
        guard !subjectEvents.isEmpty else { return nil }

        let composed: EventAnswerComposition?
        if asksStatus {
            composed = EventAnswerComposer.composeStatus(
                question: question, events: subjectEvents, documentsSearched: 0)
        } else {
            composed = EventAnswerComposer.composeSubjectEvents(
                question: question, events: subjectEvents,
                subjectLabel: charter.anchors.first.map { SubjectResolver.displayLabel(for: $0) })
        }
        guard let composed else { return nil }
        var body = composed.primaryText
        if let about = charter.footerText { body += "\n\n" + about }
        body += "\n\n(\(composed.receiptLine))"
        KalsmritikoshLog.brain.info("subject-first: \(asksStatus ? "status" : "events", privacy: .public) answered from \(subjectEvents.count, privacy: .public) subject event(s)")
        return VerifiedAnswer(
            body: body,
            answerText: composed.primaryText,
            intentKind: UserIntent.Kind.factualLookup.rawValue,
            citations: composed.supportingEvents.map {
                VerifiedAnswer.Citation(objectID: $0.sourceObjectID, eventID: $0.id, snippet: $0.title)
            },
            confidence: composed.supportingEvents.first?.confidence ?? Confidence(0.8),
            refused: false,
            answerState: .supported)
    }

    /// L5 — "who is ‹name›…" from the correspondence ledger; "what jobs have I
    /// held" from the OWNER's own facts. nil → the next door / the pipeline.
    func composePersonAnswer(question: String) async -> VerifiedAnswer? {
        guard let database, let events else { return nil }
        let participants = EmailParticipantRepository(database: database)
        if let name = PersonAnswerComposer.personName(in: question) {
            let token = name.split(separator: " ").first.map(String.init) ?? name
            let rows = ((try? await participants.correspondence(nameToken: token)) ?? [])
                .map { PersonAnswerComposer.Correspondence(address: $0.address, displayName: $0.displayName,
                                                           sourceObjectID: $0.sourceObjectID, role: $0.role) }
            guard !rows.isEmpty else { return nil }
            var mail: [Event] = []
            for ko in Set(rows.map(\.sourceObjectID)).prefix(200) {
                mail += ((try? await events.findBySourceObject(ko)) ?? [])
                    .filter { $0.kind == .emailReceived || $0.kind == .emailSent }
            }
            guard let composed = PersonAnswerComposer.composeWhoIs(name: name, rows: rows, emailEvents: mail)
            else { return nil }
            KalsmritikoshLog.brain.info("subject-first: person answered from \(rows.count, privacy: .public) correspondence row(s)")
            return Self.deterministicAnswer(composed.primaryText, receipt: composed.receiptLine,
                citations: composed.supportingEvents.map {
                    VerifiedAnswer.Citation(objectID: $0.sourceObjectID, eventID: $0.id, snippet: $0.title)
                })
        }
        if PersonAnswerComposer.asksOwnJobs(question), let facts = genericFacts, let evidenceStore {
            let owners = (try? await participants.likelyOwnerAddresses()) ?? []
            var labels: [String] = []
            for address in owners { labels += (try? await facts.subjectLabels(statingValue: address)) ?? [] }
            let ownerLabels = Array(NSOrderedSet(array: labels).compactMap { $0 as? String }.prefix(6))
            guard !ownerLabels.isEmpty else { return nil }
            let jobFacts = (try? await facts.facts(
                subjectLabels: ownerLabels,
                fields: PersonAnswerComposer.employerFields.union(PersonAnswerComposer.roleFields))) ?? []
            guard let composed = PersonAnswerComposer.composeOwnJobs(ownerLabel: ownerLabels[0], facts: jobFacts)
            else { return nil }
            var citations: [VerifiedAnswer.Citation] = []
            for f in composed.facts {
                guard let block = f.sourceBlockIDs.first,
                      let ko = try? await evidenceStore.owningObject(forBlock: block) else { continue }
                citations.append(VerifiedAnswer.Citation(objectID: ko, snippet: "\(f.field): \(f.value)"))
            }
            guard !citations.isEmpty else { return nil }
            KalsmritikoshLog.brain.info("subject-first: own jobs answered from \(jobFacts.count, privacy: .public) owner fact(s)")
            return Self.deterministicAnswer(composed.text,
                receipt: "The owner is the address this mailbox is delivered to; only documents stating that address count as yours; no model was consulted.",
                citations: citations)
        }
        return nil
    }

    static func deterministicAnswer(_ text: String, receipt: String, citations: [VerifiedAnswer.Citation]) -> VerifiedAnswer {
        VerifiedAnswer(
            body: text + "\n\n(" + receipt + ")",
            answerText: text,
            intentKind: UserIntent.Kind.factualLookup.rawValue,
            citations: citations,
            confidence: Confidence(0.85),
            refused: false,
            answerState: .supported)
    }
}
