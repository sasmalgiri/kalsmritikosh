//
//  CaseEnrichment.swift
//  Kalsmritikosh
//
//  Smart-map S12 (ADAPT-07) — the typed result every external enrichment adapter returns: CANDIDATE records (never case
//  records), each with where it came from, when it was retrieved, what was asked, which page, what it cost and its
//  restrictions — and a status that keeps "no match" apart from "denied", "failed" and "partial", so an empty list is never
//  read as a clean result. Pure: the lookups themselves stay in Routing/Providers (the only place that opens a
//  connection); this file only shapes what they returned. Commercial providers are blocked until their subscriptions and
//  keys exist (docs/INTEROP_CONTRACTS.md).
//

import Foundation

public nonisolated struct CaseEnrichmentResult: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The lookup ran completely and found candidates.
        case matches
        /// The lookup ran completely and found nothing.
        case noMatch
        /// Nothing was asked: offline, declined by the person, or no permission / key.
        case denied
        /// The lookup was asked and failed (HTTP error, unreadable answer).
        case failed
        /// Some pages or lists answered and some did not: the candidates are incomplete.
        case partial
    }
    public struct Candidate: Sendable, Equatable {
        public let kind: String          // "person or organisation", "listed entity", "court record"
        public let label: String
        public let identifiers: [String]
        public let detail: String
        public let exact: Bool
    }

    public let origin: String
    public let retrievedAt: Date
    public let inputScope: String
    public let page: Int
    public let hasMore: Bool
    /// What it cost, as the provider reported it (nil: free or not reported).
    public let cost: String?
    public let restrictions: [String]
    public let status: Status
    public let reason: String?
    public let candidates: [Candidate]

    /// What the person reads: never an empty list without saying why it is empty.
    public var summary: String {
        switch status {
        case .matches: return "\(candidates.count) candidate(s) from \(origin) — leads to review, not findings."
        case .noMatch: return "No match in \(origin) for \(inputScope). This says nothing about sources not searched."
        case .denied: return "Not searched: \(reason ?? "the lookup was not allowed"). This is not a “no match”."
        case .failed: return "The lookup failed: \(reason ?? "no answer"). This is not a “no match”."
        case .partial: return "Incomplete: \(reason ?? "part of the lookup failed"). \(candidates.count) candidate(s) so far; absence is not a “no match”."
        }
    }
}

public nonisolated enum CaseEnrichmentAdapters {
    /// A local sanctions-list search (the lists downloaded on this Mac; the name is not sent). `failedLists` names lists
    /// that could not be downloaded: then the result is partial, never a clean "no match".
    public static func sanctions(query: String, matches: [SanctionsLists.Match], searched: [PublicSource], failedLists: [PublicSource],
                                 at date: Date) -> CaseEnrichmentResult {
        let candidates = matches.map {
            CaseEnrichmentResult.Candidate(kind: "listed entity", label: $0.entry.name, identifiers: [$0.entry.reference],
                                           detail: "\($0.entry.list.displayName): \($0.entry.detail)", exact: $0.exact)
        }
        let status: CaseEnrichmentResult.Status
        if searched.isEmpty { status = failedLists.isEmpty ? .denied : .failed }
        else if !failedLists.isEmpty { status = .partial }
        else { status = candidates.isEmpty ? .noMatch : .matches }
        return CaseEnrichmentResult(origin: searched.map(\.displayName).joined(separator: "; ").nilIfEmpty ?? "sanctions lists", retrievedAt: date,
                                    inputScope: "the name “\(query)”", page: 1, hasMore: false, cost: nil,
                                    restrictions: ["A name match is a possible match until identifiers agree."],
                                    status: status, reason: failedLists.isEmpty ? nil : "could not read " + failedLists.map(\.displayName).joined(separator: ", "),
                                    candidates: candidates)
    }

    /// A registry or court lookup that was sent (GLEIF, CourtListener), or refused / failed before an answer.
    public static func registry(source: PublicSource, query: String, outcome: Result<[RegistryLookups.Record], OnlineLookupClient.LookupError>,
                                page: Int = 1, hasMore: Bool = false, at date: Date) -> CaseEnrichmentResult {
        switch outcome {
        case .success(let records):
            let c = records.map { CaseEnrichmentResult.Candidate(kind: source == .gleif ? "organisation" : "court record", label: $0.title,
                                                                 identifiers: [$0.link], detail: $0.detail, exact: false) }
            return CaseEnrichmentResult(origin: source.displayName, retrievedAt: date, inputScope: "the name “\(query)” (sent to \(source.host))",
                                        page: page, hasMore: hasMore, cost: nil, restrictions: ["Results are leads, not case records."],
                                        status: hasMore && !c.isEmpty ? .partial : (c.isEmpty ? .noMatch : .matches),
                                        reason: hasMore ? "more pages were not read" : nil, candidates: c)
        case .failure(let e):
            let denied: Bool = { switch e { case .offline, .declined, .logUnavailable: return true; default: return false } }()
            return CaseEnrichmentResult(origin: source.displayName, retrievedAt: date, inputScope: "the name “\(query)”", page: page, hasMore: false,
                                        cost: nil, restrictions: [], status: denied ? .denied : .failed, reason: e.localizedDescription, candidates: [])
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
