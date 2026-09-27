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
}
