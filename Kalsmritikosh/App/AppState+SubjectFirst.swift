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
        if let (phrase, tokens) = PaymentAnswerComposer.payee(in: question), let facts = genericFacts, let evidenceStore {
            let payees = ((try? await facts.facts(field: "counterparty", limit: 2_000)) ?? [])
                .filter { PaymentAnswerComposer.counterpartyMatches($0.value, tokens: tokens) }
            let labels = Array(NSOrderedSet(array: payees.map(\.subjectLabel)).compactMap { $0 as? String })
            guard !labels.isEmpty else { return nil }
            // Group by SOURCE DOCUMENT, not label: payment screenshots routinely
            // share a title ("Transaction Successful"), and one label would merge
            // separate payments.
            func document(of f: GenericFact) async -> UUID? {
                for block in f.sourceBlockIDs {
                    if let ko = try? await evidenceStore.owningObject(forBlock: block) { return ko }
                }
                return nil
            }
            var payeeDocs = Set<UUID>()
            for p in payees { if let ko = await document(of: p) { payeeDocs.insert(ko) } }
            let money = (try? await facts.facts(subjectLabels: labels, fields: ["amount", "date"])) ?? []
            var byDoc: [UUID: (label: String, amounts: [GenericFact], dates: [GenericFact])] = [:]
            for f in money {
                guard let ko = await document(of: f), payeeDocs.contains(ko) else { continue }
                var entry = byDoc[ko] ?? (label: f.subjectLabel, amounts: [], dates: [])
                if f.field == "amount" { entry.amounts.append(f) } else { entry.dates.append(f) }
                byDoc[ko] = entry
            }
            let docs = byDoc.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value)
            guard let composed = PaymentAnswerComposer.compose(payeePhrase: phrase, documents: docs) else { return nil }
            var citations: [VerifiedAnswer.Citation] = []
            for f in composed.facts {
                guard let block = f.sourceBlockIDs.first,
                      let ko = try? await evidenceStore.owningObject(forBlock: block) else { continue }
                citations.append(VerifiedAnswer.Citation(objectID: ko, snippet: "amount: \(f.value)"))
            }
            guard !citations.isEmpty else { return nil }
            KalsmritikoshLog.brain.info("subject-first: payments answered from \(labels.count, privacy: .public) payment document(s)")
            return Self.deterministicAnswer(composed.text,
                receipt: "Summed from the payment confirmations' own amount facts, per currency; no model was consulted.",
                citations: citations)
        }
        if PersonAnswerComposer.asksOwnJobs(question), let facts = genericFacts, let evidenceStore {
            let owners = (try? await participants.likelyOwnerAddresses()) ?? []
            // The owner's subjects: named as the owner (the names the owner's
            // address sends under), or stating the owner's FULL address as a
            // whole token. Other candidates' CVs addressed to the owner carry
            // at most a truncated form and never qualify.
            var labels: [String] = []
            for address in owners {
                for name in (try? await participants.displayNames(sentBy: address)) ?? [] {
                    labels += (try? await facts.subjectLabels(named: name)) ?? []
                }
                labels += (try? await facts.subjectLabels(containingToken: address)) ?? []
            }
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
