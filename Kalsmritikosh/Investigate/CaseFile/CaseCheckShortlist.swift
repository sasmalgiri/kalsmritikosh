//
//  CaseCheckShortlist.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (ACTION-14, ACTION-15) — the investigative checks worth doing next, kept apart from the case's
//  ordinary obligations (CaseNextSteps):
//    • one check per observation: proposals that ask for the same thing from the same target (several methods proposing
//      one certificate request) become ONE check that keeps every explanation it serves; proposals about different targets
//      (two similar payments to different people) never merge;
//    • ranked by explainable rules, in this order: a deadline with a recorded source (sooner first), then how many open
//      explanations the check bears on (more first), then known effort (less first); unknown deadlines and efforts stay
//      unknown and are said so; ties are stable (title, then id);
//    • a person may move a check, with a reason; the override is applied after the rules and shown with its reason.
//  Rank is an order of work, never a likelihood that anything is true. Deterministic; no AI.
//

import Foundation

public nonisolated struct CaseCheckCandidate: Sendable, Equatable {
    public enum Origin: String, Sendable { case method, request, contradiction, gap }
    public var id: String
    public var title: String
    /// What is to be observed or obtained, and from what or whom — the merge key is built from these two (normalised).
    public var observation: String
    public var target: String
    public var origin: Origin
    /// A deadline and where it comes from (nil source: not a sourced deadline — it does not rank first).
    public var deadline: Date?
    public var deadlineSource: String?
    /// The open explanations (hypotheses, questions) this check bears on.
    public var explanations: Set<UUID> = []
    /// Known effort in hours (nil: unknown).
    public var effortHours: Double?
    public init(id: String, title: String, observation: String, target: String, origin: Origin, deadline: Date? = nil,
                deadlineSource: String? = nil, explanations: Set<UUID> = [], effortHours: Double? = nil) {
        self.id = id; self.title = title; self.observation = observation; self.target = target; self.origin = origin
        self.deadline = deadline; self.deadlineSource = deadlineSource; self.explanations = explanations; self.effortHours = effortHours
    }
}

/// A person's change to the order, with the reason (applied after the rules).
public nonisolated struct CaseCheckOverride: Sendable, Equatable {
    public var checkID: String
    /// The position the person put it at (0 = first).
    public var position: Int
    public var reason: String
    public init(checkID: String, position: Int, reason: String) { self.checkID = checkID; self.position = position; self.reason = reason }
}

public nonisolated struct CaseCheck: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let observation: String
    public let target: String
    /// Every proposal merged into this check (several methods may propose the same observation).
    public let mergedFrom: [String]
    public let origins: [CaseCheckCandidate.Origin]
    public let explanations: Set<UUID>
    public let deadline: Date?
    public let deadlineSource: String?
    public let effortHours: Double?
    /// Why it sits where it does, in words (rules), and the person's reason when they moved it.
    public let why: String
    public let overrideReason: String?
}

public nonisolated enum CaseCheckShortlist {

    /// How many checks the short list shows before "Show all".
    public static let shortlistSize = 3

    /// Words that do not change what is asked for ("certificate for HPLC-2" and "certificate — HPLC-2" ask for one thing).
    static let functionWords: Set<String> = ["a", "an", "the", "of", "for", "from", "to", "on", "in", "at", "by", "and", "with"]

    static func key(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !functionWords.contains($0) }.joined(separator: " ")
    }

    /// Merge proposals for the same observation from the same target; keep each merged proposal's id and explanations.
    public static func merge(_ candidates: [CaseCheckCandidate]) -> [CaseCheckCandidate] {
        var order: [String] = []
        var merged: [String: (c: CaseCheckCandidate, ids: [String], origins: [CaseCheckCandidate.Origin])] = [:]
        for c in candidates {
            let k = key(c.observation) + "|" + key(c.target)
            if var m = merged[k] {
                m.c.explanations.formUnion(c.explanations)
                // The sooner sourced deadline and the smaller known effort of the merged proposals.
                if let d = c.deadline, c.deadlineSource != nil, m.c.deadlineSource == nil || (m.c.deadline.map { d < $0 } ?? true) {
                    m.c.deadline = d; m.c.deadlineSource = c.deadlineSource
                }
                if let e = c.effortHours { m.c.effortHours = min(e, m.c.effortHours ?? e) }
                m.ids.append(c.id); m.origins.append(c.origin)
                merged[k] = m
            } else {
                order.append(k); merged[k] = (c, [c.id], [c.origin])
            }
        }
        return order.compactMap { k in
            guard let m = merged[k] else { return nil }
            var c = m.c
            c.id = m.ids.sorted().joined(separator: "+")
            return c
        }
    }

    /// The ranked checks (all of them — `shortlistSize` is what the view shows first), with overrides applied.
    public static func rank(_ candidates: [CaseCheckCandidate], overrides: [CaseCheckOverride] = [], now: Date = Date()) -> [CaseCheck] {
        // Keep the merged ids and origins beside each merged candidate.
        var provenance: [String: (ids: [String], origins: [CaseCheckCandidate.Origin])] = [:]
        var order: [String] = []
        for c in candidates {
            let k = key(c.observation) + "|" + key(c.target)
            if provenance[k] == nil { order.append(k) }
            provenance[k, default: ([], [])].ids.append(c.id)
            provenance[k, default: ([], [])].origins.append(c.origin)
        }
        let merged = merge(candidates)
        func sourcedDeadline(_ c: CaseCheckCandidate) -> Date? { c.deadlineSource == nil ? nil : c.deadline.flatMap { $0 >= now ? $0 : nil } }
        let ruled = merged.sorted { a, b in
            switch (sourcedDeadline(a), sourcedDeadline(b)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.explanations.count != b.explanations.count { return a.explanations.count > b.explanations.count }
            switch (a.effortHours, b.effortHours) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return a.title != b.title ? a.title < b.title : a.id < b.id
        }
        func why(_ c: CaseCheckCandidate) -> String {
            var parts: [String] = []
            if let d = sourcedDeadline(c), let s = c.deadlineSource {
                parts.append("deadline \(d.formatted(date: .abbreviated, time: .omitted)) (\(s))")
            } else if c.deadline != nil && c.deadlineSource == nil {
                parts.append("a date is noted but its source is not, so it does not rank as a deadline")
            } else {
                parts.append("no sourced deadline")
            }
            parts.append(c.explanations.isEmpty ? "bears on no recorded explanation" : "bears on \(c.explanations.count) open explanation(s)")
            parts.append(c.effortHours.map { "about \($0.formatted()) hour(s) of work" } ?? "effort unknown")
            return parts.joined(separator: "; ") + ". The order is for work, not a measure of what is true."
        }
        var list: [(CaseCheckCandidate, String?)] = ruled.map { ($0, nil) }
        for o in overrides {
            guard let i = list.firstIndex(where: { $0.0.id == o.checkID || $0.0.id.split(separator: "+").map(String.init).contains(o.checkID) }) else { continue }
            let item = list.remove(at: i)
            list.insert((item.0, o.reason), at: max(0, min(o.position, list.count)))
        }
        return list.map { c, reason in
            let k = key(c.observation) + "|" + key(c.target)
            let p = provenance[k] ?? ([c.id], [c.origin])
            return CaseCheck(id: c.id, title: c.title, observation: c.observation, target: c.target, mergedFrom: p.ids, origins: p.origins,
                             explanations: c.explanations, deadline: c.deadline, deadlineSource: c.deadlineSource, effortHours: c.effortHours,
                             why: why(c), overrideReason: reason)
        }
    }

    /// The case's open evidence requests and contradictions awaiting review as candidate checks. A request's deadline is
    /// sourced (it is the date recorded on the request); a contradiction bears on the explanations its sides concern.
    public static func candidates(requests: [EvidenceRequestFile], awaitingContradictions: [(id: UUID, summary: String)],
                                  openExplanations: [InvestigationHypothesis]) -> [CaseCheckCandidate] {
        var out: [CaseCheckCandidate] = []
        let open = Set(openExplanations.filter { $0.status == .proposed }.map(\.id))
        for f in requests where f.request.status.isOutstanding {
            let r = f.request
            let item = f.progress.outstanding.map(\.label).joined(separator: ", ")
            out.append(CaseCheckCandidate(id: "request:" + r.id.uuidString, title: r.description,
                                          observation: item.isEmpty ? r.description : item, target: r.custodian ?? "", origin: .request,
                                          deadline: r.dueAt, deadlineSource: r.dueAt == nil ? nil : "the date recorded on the request",
                                          explanations: Set([r.hypothesisID].compactMap { $0 }).intersection(open)))
        }
        for c in awaitingContradictions {
            out.append(CaseCheckCandidate(id: "contradiction:" + c.id.uuidString, title: "Decide: " + c.summary, observation: c.summary,
                                          target: "", origin: .contradiction))
        }
        return out
    }
}
