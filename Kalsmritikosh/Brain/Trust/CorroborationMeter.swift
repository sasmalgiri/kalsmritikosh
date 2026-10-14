//
//  CorroborationMeter.swift
//  Kalsmritikosh
//
//  I-3 — "cited" is not "proven". Groups an answer's cited sources by their
//  independence key (content hash, message id, lineage — HIST-035) so five
//  copies of one email count once, and says plainly when an answer rests on a
//  single source. Uses the CONSERVATIVE count: a source with no reliable key is
//  shown but never counted as independent corroboration (C2 safeguard).
//  Pure and deterministic.
//

import Foundation

public nonisolated struct CorroborationReading: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        /// No cited source at all.
        case none
        /// One independent source (or only unkeyed ones): a lead, not a fact.
        case singleSource
        /// Two or more independent sources.
        case corroborated
    }

    /// Distinct cited documents.
    public let citedSources: Int
    /// Groups of cited documents that are copies of one another.
    public let groups: [[KnowledgeObject.ID]]
    /// Independent sources with a reliable identity (conservative count).
    public let verifiedIndependent: Int
    /// Cited documents whose identity could not be established.
    public let unkeyed: Int
    public let verdict: Verdict

    /// Groups with more than one member — the copies the user should know about.
    public var copyGroups: [[KnowledgeObject.ID]] { groups.filter { $0.count > 1 } }

    public var headline: String {
        switch verdict {
        case .none:
            return "No sources cited"
        case .singleSource:
            return "Single source — treat this as a lead, not a fact"
        case .corroborated:
            return "\(verifiedIndependent) independent sources"
        }
    }

    public var detail: String {
        var parts: [String] = []
        parts.append("\(citedSources) document\(citedSources == 1 ? "" : "s") cited")
        let copies = copyGroups.reduce(0) { $0 + $1.count - 1 }
        if copies > 0 { parts.append("\(copies) of them \(copies == 1 ? "is a copy" : "are copies") of another cited document") }
        if unkeyed > 0 { parts.append("\(unkeyed) could not be identified as independent, so \(unkeyed == 1 ? "it does" : "they do") not count") }
        return parts.joined(separator: "; ") + "."
    }
}

public nonisolated enum CorroborationMeter {

    public static func read(citedObjectIDs: [KnowledgeObject.ID],
                            keys: [KnowledgeObject.ID: String]) -> CorroborationReading {
        var seen = Set<KnowledgeObject.ID>()
        let distinct = citedObjectIDs.filter { seen.insert($0).inserted }
        guard !distinct.isEmpty else {
            return CorroborationReading(citedSources: 0, groups: [], verifiedIndependent: 0, unkeyed: 0, verdict: .none)
        }
        let grouper = SourceIndependenceGrouper()
        let groups = grouper.groups(objectIDs: distinct, keys: keys)
        let verified = grouper.verifiedIndependentCount(objectIDs: distinct, keys: keys)
        let unkeyed = distinct.filter { oid in
            (keys[oid]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }.count
        return CorroborationReading(citedSources: distinct.count,
                                    groups: groups,
                                    verifiedIndependent: verified,
                                    unkeyed: unkeyed,
                                    verdict: verified >= 2 ? .corroborated : .singleSource)
    }
}
