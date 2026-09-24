//
//  HistoryLayerDiagnosis.swift
//  Kalsmritikosh
//
//  B-2 (the part that needs no owner input) — WHY is there no story?
//
//  Same defect as the topic layer, one layer over. "No history for this subject"
//  is shown identically whether the archive holds nothing about them, the events
//  exist but are not attached to anyone, the reconstruction has never run, or
//  the subject name simply did not resolve to a known entity.
//
//  THE SHARP LINK IS `event_entities`. A story is per-subject, and an event
//  reaches a subject only through that join. The join can be empty while the
//  `events` table is large and healthy-looking — and in that state EVERY
//  subject's history is empty, with the archive-wide event count giving no hint
//  at all. It is the one link here whose absence is invisible from every
//  aggregate the app otherwise reports, which is exactly why it is checked
//  explicitly rather than inferred from the event total.
//
//  Note what is NOT a failure mode: `events.date` is `REAL NOT NULL`, so an
//  undated event cannot exist. Checking for one would be inventing a hazard the
//  schema already forecloses, and a diagnosis that reports impossible states
//  teaches the reader to distrust the possible ones.
//
//  WHAT THIS DELIBERATELY DOES NOT DO. It does not judge whether a particular
//  subject's story is CORRECT, complete, or well-ordered. That needs named
//  subjects — including an ambiguous one — chosen by the owner, and it is
//  recorded as owner-blocked rather than approximated here with a subject I
//  picked myself. A self-chosen subject would prove only that the machinery
//  runs on a case selected because it runs.
//
//  Read-only, archive-wide, no subject required.
//

import Foundation
import os

public struct HistoryLayerDiagnosis: Sendable {

    public enum LinkID: String, Sendable, CaseIterable {
        case idleBuildSetting
        case entities
        case events
        case eventParticipants
        case subjectMaterial
        case storedStories
        case citedItems

        public var displayName: String {
            switch self {
            case .idleBuildSetting:   return "background story building"
            case .entities:           return "subjects"
            case .events:             return "dated events"
            case .eventParticipants:  return "events linked to subjects"
            case .subjectMaterial:    return "facts about subjects"
            case .storedStories:      return "stored stories"
            case .citedItems:         return "story items with citations"
            }
        }
    }

    public struct Link: Sendable {
        public let id: LinkID
        public let outcome: PipelineStageOutcome
        public let remedy: String
        public var name: String { id.displayName }
    }

    public let links: [Link]
    public let firstMissing: Link?
    public let emptyButCorrect: Bool

    public var headline: String {
        if let firstMissing {
            if emptyButCorrect {
                return "No stories yet — and that is correct here: \(firstMissing.name)"
            }
            return "No stories — the chain stops at “\(firstMissing.name)”"
        }
        return "Stories are built and cited"
    }

    public func renderLines() -> String {
        var out = "HISTORY LAYER\n  \(headline)\n"
        for l in links { out += "  \(l.outcome.symbol) \(l.name): \(l.outcome.line)\n" }
        if let firstMissing, !firstMissing.remedy.isEmpty {
            out += "\n  WHAT TO DO: \(firstMissing.remedy)\n"
        }
        return out
    }

    // MARK: - Build

    public static func run(database: Database) async -> HistoryLayerDiagnosis {
        var links: [Link] = []
        func add(_ id: LinkID, _ outcome: PipelineStageOutcome, remedy: String = "") {
            links.append(Link(id: id, outcome: outcome, remedy: remedy))
        }
        func scalar(_ sql: String) async -> Int? {
            guard let rows = try? await database.query(sql, []) else { return nil }
            return Int(rows.first?.int(0) ?? 0)
        }

        // ── 0. the setting ──────────────────────────────────────────────────
        let idleOn = KnowledgeModuleFlags.isEnabled(.historyAtIdle)
        add(.idleBuildSetting, idleOn
            ? .present(count: 1, detail: "stories are reconstructed during idle maintenance")
            : .absentExpected(reason: "background story building is switched OFF. Stories are still built ON DEMAND when you ask for one — this only means none are prepared in advance"),
            remedy: idleOn ? "" : "Nothing is required: ask about a subject and its story is reconstructed then. Turn on “History at idle” in Settings → Modules to have them prepared ahead of time.")

        // ── 1. subjects ─────────────────────────────────────────────────────
        guard let entities = await scalar(
            "SELECT COUNT(*) FROM entities WHERE merged_into IS NULL;") else {
            add(.entities, .couldNotCheck(why: "the entity count query failed"))
            return finish(links)
        }
        guard entities > 0 else {
            add(.entities, .absentExpected(reason: "no named things are known yet, and a story is always the story OF something"),
                remedy: "Ingest documents first. If documents are already ingested and this is still zero, the Data Health report's language and failure sections explain why nothing was recognised.")
            return finish(links, emptyButCorrect: true)
        }
        add(.entities, .present(count: entities, detail: "possible subjects"))

        // ── 2. events ───────────────────────────────────────────────────────
        guard let events = await scalar("SELECT COUNT(*) FROM events;") else {
            add(.events, .couldNotCheck(why: "the event count query failed"))
            return finish(links)
        }
        guard events > 0 else {
            add(.events, .absentExpected(reason: "no dated events were extracted, so there is no chronology to tell. Common and often correct — an archive of undated documents genuinely has no timeline"),
                remedy: "If your documents DO carry dates, this is an extraction gap: check the Data Health report for the formats involved.")
            return finish(links, emptyButCorrect: true)
        }
        add(.events, .present(count: events, detail: "dated events"))

        // ── 3. THE SHARP LINK ───────────────────────────────────────────────
        //
        // Without this join an event belongs to no one. Every subject's story is
        // then empty while `events` above reports a healthy number — the one
        // failure here that no aggregate in the app would reveal.
        guard let participants = await scalar(
            "SELECT COUNT(DISTINCT event_id) FROM event_entities;") else {
            add(.eventParticipants, .couldNotCheck(why: "the event_entities query failed"))
            return finish(links)
        }
        if participants == 0 {
            add(.eventParticipants, .absentUnexpected(reason: "\(events) dated event(s) exist but NONE is linked to a subject. A story is always about someone or something, so every subject's story is empty — and the event count above gives no hint of it"),
                remedy: "Rebuild the ledger (Settings → re-ingest, or let the background drain run). If this stays at zero, event-to-entity linking is failing and the knowledge log records the reason.")
            return finish(links)
        }
        let linkedPct = Int((Double(participants) / Double(events) * 100).rounded())
        add(.eventParticipants, participants < events
            ? .present(count: participants, detail: "of \(events) event(s) are attached to a subject (\(linkedPct)%) — the rest cannot appear in any subject's story")
            : .present(count: participants, detail: "every event is attached to a subject"))

        // ── 4. material beyond the timeline ─────────────────────────────────
        guard let facts = await scalar("SELECT COUNT(*) FROM generic_facts;") else {
            add(.subjectMaterial, .couldNotCheck(why: "the fact count query failed"))
            return finish(links)
        }
        add(.subjectMaterial, facts > 0
            ? .present(count: facts, detail: "structured facts available as story material")
            : .absentExpected(reason: "no structured facts. Stories can still be told from the dated events alone; they will be thinner, carrying what happened and when but fewer particulars"))

        // ── 5. stored stories ───────────────────────────────────────────────
        guard let artifacts = await scalar("SELECT COUNT(*) FROM history_artifacts;") else {
            add(.storedStories, .couldNotCheck(why: "the history_artifacts query failed"))
            return finish(links)
        }
        if artifacts == 0 {
            // NOT a defect. Stories are reconstructed on demand; none stored is
            // the normal state of a healthy archive nobody has asked yet.
            add(.storedStories, .absentExpected(reason: "no story has been reconstructed and stored yet. Stories are built when you ask for one\(idleOn ? ", and during idle maintenance" : ""), so an empty store means none has been requested — not that none can be told"),
                remedy: "Ask about a subject — open Library and tap a topic, or ask “tell me the story of …”.")
            return finish(links, emptyButCorrect: true)
        }
        add(.storedStories, .present(count: artifacts, detail: "reconstructed stories held in the ledger"))

        // ── 6. citations — an uncited story is not evidence ──────────────────
        guard let items = await scalar("SELECT COUNT(*) FROM history_items;"),
              let cited = await scalar("SELECT COUNT(DISTINCT history_item_id) FROM history_item_evidence;") else {
            add(.citedItems, .couldNotCheck(why: "the story-item or evidence query failed"))
            return finish(links)
        }
        if items == 0 {
            add(.citedItems, .absentUnexpected(reason: "\(artifacts) stored story(ies) contain no items — the stories exist as shells with nothing in them"),
                remedy: "Rebuild the story for that subject. If items stay empty, the reconstruction engine is failing after creating the artifact.")
        } else if cited == 0 {
            add(.citedItems, .absentUnexpected(reason: "\(items) story item(s) carry NO evidence links. Each is an unsupported assertion, and this product's contract is that every claim names its sources"),
                remedy: "Rebuild the stories. Uncited items should not be shown; if they persist, the evidence-linking step is failing.")
        } else if cited < items {
            add(.citedItems, .present(count: cited, detail: "of \(items) item(s) are backed by evidence — \(items - cited) are NOT, and an uncited item should not be presented as established"))
        } else {
            add(.citedItems, .present(count: cited, detail: "every story item names its evidence"))
        }

        return finish(links)
    }

    private static func finish(_ links: [Link], emptyButCorrect: Bool = false) -> HistoryLayerDiagnosis {
        HistoryLayerDiagnosis(links: links,
                              firstMissing: links.first { !$0.outcome.isPopulated },
                              emptyButCorrect: emptyButCorrect)
    }
}
