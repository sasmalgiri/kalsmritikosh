//
//  InvestigationContradictionGapService+Drafts.swift
//  Kalsmritikosh
//
//  P5 — the case drafts (Case file › Overview › Drafts): a proposed chronology, the cast of characters,
//  gaps and next leads, and an interview plan, from exactly the documents the case authorizes. The rules
//  always run on the Mac (CaseDraftBuilder); with "Draft with AI", the person's reader also reads the
//  passages CloudSourceGate clears for the case's scope (privileged and above-confidential material
//  never), and every item it proposes is verified before it is shown. Nothing is written here: each
//  item is a proposal the investigator accepts through the case file's own write paths, or rejects.
//

import Foundation
import os

extension InvestigationContradictionGapService {

    /// A drafting reader is set up (Online, document reading on, AI allowed).
    public func draftReaderAvailable() -> Bool { pass?.draftReader?() != nil }

    /// The case's in-scope documents (defence in depth: only versions the case authorizes).
    private func draftDocuments(_ caseID: UUID) async throws -> [CaseDraftBuilder.Document] {
        guard let pass else { return [] }
        let authorized = try await authorizedSet(caseID)
        return try await pass.documents(authorized).filter { $0.sourceVersionID.map(authorized.contains) ?? false }
    }

    /// The documents that may leave the Mac for this case's drafts, with their clearance.
    private func clearDrafts(_ caseID: UUID, docs: [CaseDraftBuilder.Document], purpose: String)
        async -> (clearance: CloudSourceClearance?, cleared: [CaseDraftBuilder.Document], denied: Int, why: String?) {
        guard let gate = pass?.gate(caseID) else {
            return (nil, [], 0, "documents cannot be cleared for the cloud (no protection labels)")
        }
        let (clearance, denied) = await gate.clear(docs.map(\.objectID), purpose: purpose)
        let cleared = docs.filter { clearance.clearedObjectIDs.contains($0.objectID) }
        return (clearance, cleared, denied.count, cleared.isEmpty ? "none of the case's documents may leave the Mac" : nil)
    }

    /// Draft the chronology, cast and leads. `useAI`: the person pressed "Draft with AI" (a reader is used
    /// only when one is set up). The case's own contradictions are read, not re-run.
    public func buildDrafts(caseID: UUID, useAI: Bool) async throws -> CaseDrafts {
        var out = CaseDrafts()
        guard let pass else { out.available = false; return out }
        let docs = try await draftDocuments(caseID)
        out.documents = docs.count
        let contradictions = try await contradictions(caseID: caseID).map(\.contradiction)
        let reader = pass.draftReader?()
        out.readerAvailable = reader != nil
        var clearance: CloudSourceClearance?
        var cleared: [CaseDraftBuilder.Document] = []
        // Plan A — the whole case (it fits, its permission is stored): one role call and one drafting call
        // over the questions' cached prefix. Otherwise passages; under the stored permission when the
        // case is too large to read whole (no second per-send preview for its documents).
        var whole: (reader: CaseReader, prepared: CaseWholeReading.Prepared, plan: CaseWholeReading)?
        var permitted: CaseReadPermittedSet?
        if useAI, reader != nil {
            switch await analysisRoute(caseID) {
            case .wholeCase(let r, let prepared):
                if let plan = pass.caseReading { whole = (r, prepared, plan); out.readWholeCase = true }
            case .passages(let p, _):
                permitted = p
            }
            let c = await clearDrafts(caseID, docs: docs, purpose: "case.drafts")
            clearance = c.clearance; cleared = c.cleared; out.deniedForCloud = c.denied; out.notSentReason = c.why
        }
        // The cast: rules, then the verified role reading over the cleared sentences naming each person.
        var readings: [VerifiedRoleReading] = []
        let ruleCast = CaseDraftBuilder.cast(docs)
        if let whole, pass.roleReader?() != nil {
            let people = Array(ruleCast.filter { $0.kind == .person }.prefix(16).map(\.name))
            var report = VerifiedRoleReader.Report()
            if !people.isEmpty {
                do {
                    let reply = try await whole.plan.readForAnalysis(whole.reader, whole.prepared, caseID: caseID,
                                                                     task: VerifiedRoleReader.wholeCaseTask(people: people),
                                                                     replyTokens: VerifiedRoleReader.wholeCaseReplyTokens,
                                                                     purpose: "case.analysis.roles")
                    report = VerifiedRoleReader.verifyWholeCase(reply: reply.text, people: people, documents: whole.prepared.documents)
                } catch {
                    KalsmritikoshLog.knowledge.info("whole-case role reading not used: \(String(describing: error), privacy: .public)")
                    report.calls = 1
                    report.failures.append("role call (whole case): " + VerifiedRoleReader.reason(error))
                }
            }
            readings = report.readings
            out.roleBatches = report.calls
            out.roleReadings = readings.count
            out.roleDropped = report.dropped
            out.failures += report.failures
            out.failedCalls += report.failures.count
        } else if let clearance, !cleared.isEmpty, let roleReader = pass.roleReader?() {
            let people = Array(ruleCast.filter { $0.kind == .person }.prefix(16).map(\.name))
            var passages: [VerifiedRoleReader.Passage] = []
            for person in people {
                for d in cleared.filter({ ProceedingAnswerer.namesFully($0.text, person: person) }).prefix(2) {
                    let text = VerifiedRoleReader.sentences(naming: person, in: d.text)
                    if !text.isEmpty { passages.append(VerifiedRoleReader.Passage(objectID: d.objectID, text: text)) }
                }
            }
            let report = await CaseReadPermittedSet.$current.withValue(permitted) {
                await roleReader.readReporting(people: people, passages: passages, clearance: clearance)
            }
            readings = report.readings
            out.roleBatches = report.calls
            out.roleReadings = readings.count
            out.roleDropped = report.dropped
            out.failures += report.failures
            out.failedCalls += report.failures.count
        }
        out.cast = CaseDraftBuilder.cast(docs, readings: readings)
        out.timeline = CaseDraftBuilder.timeline(docs, cast: out.cast)
        out.leads = CaseDraftBuilder.leads(docs, cast: out.cast, contradictions: contradictions)
        // The chronology and gaps reading.
        func absorb(_ check: CaseDraftBuilder.TimelineVerification) {
            if check.unreadable { out.dropped.append("the reply could not be read"); return }
            out.dropped += check.dropped
            for item in check.items {
                if CaseDraftBuilder.sameAsRule(item, out.timeline.filter { $0.provenance == .rules }) { out.agreedWithRules += 1; continue }
                guard !out.timeline.contains(where: { $0.id == item.id }) else { continue }
                out.timeline.append(item); out.verified += 1
            }
            for lead in check.leads where !out.leads.contains(where: { $0.id == lead.id }) {
                out.leads.append(lead); out.verified += 1
            }
        }
        if let whole {
            do {
                let reply = try await whole.plan.readForAnalysis(whole.reader, whole.prepared, caseID: caseID,
                                                                 task: CaseDraftBuilder.wholeCaseTimelineTask(),
                                                                 replyTokens: CaseDraftBuilder.wholeCaseReplyTokens,
                                                                 purpose: "case.analysis.drafts")
                out.calls += 1
                out.passagesSent += whole.prepared.documents.count
                absorb(CaseDraftBuilder.verifyTimeline(reply: reply.text, batch: CaseDraftBuilder.wholeCaseBatch(whole.prepared.documents),
                                                       documents: docs, cast: out.cast))
            } catch let notSent as VerifiedAnswerComposer.NotSent {
                KalsmritikoshLog.knowledge.info("case drafts whole-case reading not sent: \(notSent.reason, privacy: .public)")
                out.notSentReason = notSent.reason
            } catch is CancellationError {
                KalsmritikoshLog.knowledge.info("case drafts whole-case reading cancelled")
                out.notSentReason = "cancelled"
            } catch {
                KalsmritikoshLog.knowledge.error("case drafts whole-case reading failed: \(String(describing: error), privacy: .public)")
                out.failedCalls += 1
                out.failures.append("drafting call (whole case): " + VerifiedRoleReader.reason(error))
            }
            out.timeline = CaseDraftBuilder.sorted(out.timeline)
        } else if let reader, let clearance, !cleared.isEmpty {
            let clearedIDs = clearance.clearedObjectIDs
            for batch in CaseDraftBuilder.timelineBatches(cleared) {
                guard batch.passages.allSatisfy({ clearedIDs.contains($0.objectID) }) else { continue }
                let reply: String
                do {
                    reply = try await CaseReadPermittedSet.$current.withValue(permitted) {
                        try await reader.read(CaseDraftBuilder.timelinePrompt(batch), clearance: clearance)
                    }
                } catch let notSent as VerifiedAnswerComposer.NotSent {
                    KalsmritikoshLog.knowledge.info("case drafts reading not sent: \(notSent.reason, privacy: .public)")
                    out.notSentReason = notSent.reason; break
                } catch is CancellationError {
                    KalsmritikoshLog.knowledge.info("case drafts reading cancelled")
                    out.notSentReason = "cancelled"; break
                } catch {
                    KalsmritikoshLog.knowledge.error("case drafts reading failed: \(String(describing: error), privacy: .public)")
                    out.failedCalls += 1
                    out.failures.append("drafting call: " + VerifiedRoleReader.reason(error))
                    continue
                }
                out.calls += 1
                out.passagesSent += batch.passages.count
                absorb(CaseDraftBuilder.verifyTimeline(reply: reply, batch: batch, documents: docs, cast: out.cast))
            }
            out.timeline = CaseDraftBuilder.sorted(out.timeline)
        }
        // The interview plan for each of the case's subjects (rules, on the Mac) — real-case v2 (2026-11-04):
        // no plan was ever produced unless a person was picked; "Draft questions with AI" adds the reader's.
        for person in CaseDraftBuilder.interviewPeople(out.cast) {
            var plan = CaseInterviewDraft()
            plan.person = person
            plan.readerAvailable = out.readerAvailable
            plan.questions = CaseDraftBuilder.interviewQuestions(person: person, docs: docs, contradictions: contradictions, timeline: out.timeline)
            if !plan.questions.isEmpty { out.interviews.append(plan) }
        }
        KalsmritikoshLog.knowledge.info("case drafts: \(out.timeline.count, privacy: .public) chronology item(s), \(out.cast.count, privacy: .public) in the cast, \(out.leads.count, privacy: .public) lead(s), \(out.interviews.count, privacy: .public) interview plan(s); AI \(out.verified, privacy: .public) verified, \(out.dropped.count, privacy: .public) dropped, \(out.calls + out.roleBatches, privacy: .public) call(s), \(out.failedCalls, privacy: .public) failed")
        return out
    }

    /// The interview plan for `person`: rules from the case's contradictions and the passages naming them;
    /// with "Draft with AI", the reader's questions over the cleared passages, each verified.
    public func draftInterview(caseID: UUID, person: String, useAI: Bool) async throws -> CaseInterviewDraft {
        var out = CaseInterviewDraft()
        out.person = person
        guard let pass else { return out }
        let docs = try await draftDocuments(caseID)
        let contradictions = try await contradictions(caseID: caseID).map(\.contradiction)
        let cast = CaseDraftBuilder.cast(docs)
        let timeline = CaseDraftBuilder.timeline(docs, cast: cast)
        out.questions = CaseDraftBuilder.interviewQuestions(person: person, docs: docs, contradictions: contradictions, timeline: timeline)
        let reader = pass.draftReader?()
        out.readerAvailable = reader != nil
        guard useAI, let reader else { return out }
        let c = await clearDrafts(caseID, docs: docs, purpose: "case.interviewPlan")
        out.notSentReason = c.why
        guard let clearance = c.clearance, !c.cleared.isEmpty else { return out }
        let passages = CaseDraftBuilder.interviewPassages(person: person, cleared: c.cleared, contradictions: contradictions)
        guard !passages.isEmpty, passages.allSatisfy({ clearance.clearedObjectIDs.contains($0.objectID) }) else {
            out.notSentReason = out.notSentReason ?? "no cleared passage names \(person) in full"; return out
        }
        // Plan A — the interview plan stays a small passage read (one person's sentences and the case's
        // disagreements about them); the case's stored permission covers them (no second preview).
        let permitted: CaseReadPermittedSet?
        switch await analysisRoute(caseID) {
        case .wholeCase(_, let prepared): permitted = CaseReadPermittedSet(caseID: caseID, versions: prepared.clearance.versions)
        case .passages(let p, _): permitted = p
        }
        do {
            let reply = try await CaseReadPermittedSet.$current.withValue(permitted) {
                try await reader.read(CaseDraftBuilder.interviewPrompt(person: person, passages: passages), clearance: clearance)
            }
            out.calls = 1
            out.passagesSent = passages.count
            let check = CaseDraftBuilder.verifyInterview(reply: reply, person: person, passages: passages)
            if check.unreadable { out.dropped.append("the reply could not be read") }
            out.dropped += check.dropped
            for q in check.questions where !out.questions.contains(where: { CaseDraftBuilder.normalized($0.question) == CaseDraftBuilder.normalized(q.question) }) {
                out.questions.append(q); out.verified += 1
            }
        } catch let notSent as VerifiedAnswerComposer.NotSent {
            KalsmritikoshLog.knowledge.info("interview plan reading not sent: \(notSent.reason, privacy: .public)")
            out.notSentReason = notSent.reason
        } catch {
            KalsmritikoshLog.knowledge.error("interview plan reading failed: \(String(describing: error), privacy: .public)")
            out.failedCalls = 1
            out.failures.append("interview call: " + VerifiedRoleReader.reason(error))
        }
        return out
    }
}
