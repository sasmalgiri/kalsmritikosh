//
//  CaseEnrichmentSimulation.swift
//  Kalsmritikosh
//
//  Unified path R2-E (ADAPT-07, ADAPT-10; owner 2026-11-22 round 2) — not tested yet.
//
//  ADAPT-07: TYPED enrichment provider adapters. An adapter declares its origin, destination, input scope, pagination,
//  cost model and restrictions, and returns `CaseEnrichmentResult` (candidates, never case records; "no match" kept
//  apart from denied / failed / partial). A recipe composes ONLY adapters that are configured AND authorised for the
//  case; an unconfigured or unauthorised adapter is reported as denied, never silently skipped. The commercial
//  provider is SIMULATED (a scripted dataset, no network) until the owner chooses one.
//
//  ADAPT-10: honest sending. "Network only" (an authorised lookup or specialist request, AI off) and "AI only" (the
//  supplied evidence, external enrichment off) are distinct modes; consent is per recipient and never transfers
//  between providers or to a specialist; the preview names the recipient, the selected fields and the cost before
//  anything is sent. The live send stays with the owner's integration choice; here the send is SIMULATED.
//

import Foundation

public nonisolated struct EnrichmentAdapterDescriptor: Sendable, Equatable {
    public let id: String
    public let origin: String
    public let destination: String
    public let inputScope: String
    public let pageSize: Int
    public let costPerPageMicros: Int
    public let restrictions: [String]
    public let simulated: Bool
}

public protocol EnrichmentProviderAdapter: Sendable {
    var descriptor: EnrichmentAdapterDescriptor { get }
    func lookup(query: String, page: Int, at date: Date) async -> CaseEnrichmentResult
}

/// A SIMULATED commercial registry adapter: a scripted dataset; `failPages` and `deny` script the other outcomes.
public nonisolated struct SimulatedCommercialRegistryAdapter: EnrichmentProviderAdapter {
    public let descriptor = EnrichmentAdapterDescriptor(
        id: "sim.commercial-registry", origin: "SIMULATED commercial registry", destination: "registry.simulated.invalid",
        inputScope: "a name only", pageSize: 2, costPerPageMicros: 50_000,
        restrictions: ["SIMULATED data — not a real registry", "Licensed for this case only; do not re-share"], simulated: true)
    public let dataset: [String: [String]]
    public let failPages: Set<Int>
    public let deny: Bool
    public init(dataset: [String: [String]], failPages: Set<Int> = [], deny: Bool = false) {
        self.dataset = dataset; self.failPages = failPages; self.deny = deny
    }

    public func lookup(query: String, page: Int, at date: Date) async -> CaseEnrichmentResult {
        func result(_ status: CaseEnrichmentResult.Status, _ reason: String?, _ candidates: [CaseEnrichmentResult.Candidate], hasMore: Bool, cost: Int?) -> CaseEnrichmentResult {
            CaseEnrichmentResult(origin: descriptor.origin, retrievedAt: date, inputScope: "the name “\(query)” (\(descriptor.inputScope))", page: page,
                                 hasMore: hasMore, cost: cost.map { String(format: "$%.2f (SIMULATED)", Double($0) / 1_000_000) },
                                 restrictions: descriptor.restrictions, status: status, reason: reason, candidates: candidates)
        }
        if deny { return result(.denied, "the SIMULATED provider refused this account", [], hasMore: false, cost: nil) }
        if failPages.contains(page) { return result(.failed, "SIMULATED provider error on page \(page)", [], hasMore: false, cost: nil) }
        let all = dataset.filter { $0.key.localizedCaseInsensitiveContains(query) }.sorted { $0.key < $1.key }
        let start = (page - 1) * descriptor.pageSize
        guard start < all.count || (all.isEmpty && page == 1) else { return result(.noMatch, nil, [], hasMore: false, cost: descriptor.costPerPageMicros) }
        let slice = all.isEmpty ? [] : Array(all[start..<min(all.count, start + descriptor.pageSize)])
        let candidates = slice.map { CaseEnrichmentResult.Candidate(kind: "registered company", label: $0.key, identifiers: $0.value,
                                                                     detail: "SIMULATED record", exact: $0.key.caseInsensitiveCompare(query) == .orderedSame) }
        return result(candidates.isEmpty ? .noMatch : .matches, nil, candidates, hasMore: start + descriptor.pageSize < all.count, cost: descriptor.costPerPageMicros)
    }
}

public nonisolated struct EnrichmentRecipe: Sendable {
    public struct Step: Sendable { public let adapterID: String; public let maxPages: Int
        public init(adapterID: String, maxPages: Int) { self.adapterID = adapterID; self.maxPages = maxPages } }
    public let name: String
    public let steps: [Step]
    public init(name: String, steps: [Step]) { self.name = name; self.steps = steps }

    /// Run the recipe with the configured adapters, for a case that authorised `authorized` adapter ids.
    /// Pages are combined per adapter: any failed page makes that adapter's result partial (never a clean "no match").
    public func run(query: String, configured: [any EnrichmentProviderAdapter], authorized: Set<String>, at date: Date) async -> [CaseEnrichmentResult] {
        var out: [CaseEnrichmentResult] = []
        for step in steps {
            guard let adapter = configured.first(where: { $0.descriptor.id == step.adapterID }) else {
                out.append(CaseEnrichmentResult(origin: step.adapterID, retrievedAt: date, inputScope: query, page: 0, hasMore: false, cost: nil,
                                                restrictions: [], status: .denied, reason: "this provider is not configured", candidates: []))
                continue
            }
            guard authorized.contains(step.adapterID) else {
                out.append(CaseEnrichmentResult(origin: adapter.descriptor.origin, retrievedAt: date, inputScope: query, page: 0, hasMore: false, cost: nil,
                                                restrictions: adapter.descriptor.restrictions, status: .denied,
                                                reason: "this case has not authorised \(adapter.descriptor.origin)", candidates: []))
                continue
            }
            var candidates: [CaseEnrichmentResult.Candidate] = []
            var failed = false, page = 1, hasMore = true, cost = 0, denied: String?
            while hasMore, page <= step.maxPages {
                let r = await adapter.lookup(query: query, page: page, at: date)
                switch r.status {
                case .failed: failed = true; hasMore = false
                case .denied: denied = r.reason; hasMore = false
                default: candidates += r.candidates; hasMore = r.hasMore
                }
                if r.cost != nil { cost += adapter.descriptor.costPerPageMicros }
                page += 1
            }
            let status: CaseEnrichmentResult.Status = denied != nil ? .denied : failed ? (candidates.isEmpty ? .failed : .partial)
                : hasMore ? .partial : candidates.isEmpty ? .noMatch : .matches
            out.append(CaseEnrichmentResult(origin: adapter.descriptor.origin, retrievedAt: date, inputScope: query, page: page - 1, hasMore: hasMore,
                                            cost: String(format: "$%.2f (SIMULATED)", Double(cost) / 1_000_000), restrictions: adapter.descriptor.restrictions,
                                            status: status, reason: denied ?? (failed ? "a page failed" : hasMore ? "stopped at the recipe's page limit" : nil),
                                            candidates: candidates))
        }
        return out
    }
}

// MARK: - ADAPT-10: send modes, per-recipient consent, preview

public nonisolated enum EvidenceSendMode: String, Sendable, CaseIterable {
    /// An authorised lookup or specialist request; AI is off for it.
    case networkOnly
    /// The AI reads only the supplied evidence; external enrichment is off for it.
    case aiOnly
}

public nonisolated struct EvidenceSendPreview: Sendable, Equatable {
    public let mode: EvidenceSendMode
    public let recipient: String
    public let fields: [String]
    public let estimatedCost: String
    public let label = "SIMULATED send — nothing leaves this Mac"
    public var text: String { "\(label). \(mode == .networkOnly ? "Network only (AI off)" : "AI only (enrichment off)") → \(recipient). Fields: \(fields.joined(separator: ", ")). Cost: \(estimatedCost)." }
}

public actor SimulatedEvidenceSender {
    public enum Outcome: Sendable, Equatable { case sent(EvidenceSendPreview), declined, refused(String) }
    private var consents: Set<String> = []          // "mode|recipient"
    public private(set) var sent: [EvidenceSendPreview] = []
    public nonisolated init() {}

    public func grantConsent(mode: EvidenceSendMode, recipient: String) { consents.insert("\(mode.rawValue)|\(recipient)") }

    /// A send needs consent for exactly this mode AND recipient; AI-only never carries enrichment fields and
    /// network-only never carries AI. The preview is shown (returned) before the send; `confirm` stands in for the person.
    public func send(mode: EvidenceSendMode, recipient: String, fields: [String], usesAI: Bool, usesEnrichment: Bool, costMicros: Int,
                     confirm: @Sendable (EvidenceSendPreview) async -> Bool) async -> Outcome {
        if mode == .aiOnly, usesEnrichment { return .refused("AI only: external enrichment is off for this send") }
        if mode == .networkOnly, usesAI { return .refused("Network only: AI is off for this send") }
        guard consents.contains("\(mode.rawValue)|\(recipient)") else {
            return .refused("no consent for \(recipient) in this mode (consent never transfers between recipients)")
        }
        let preview = EvidenceSendPreview(mode: mode, recipient: recipient, fields: fields,
                                          estimatedCost: String(format: "$%.2f (SIMULATED)", Double(costMicros) / 1_000_000))
        guard await confirm(preview) else { return .declined }
        sent.append(preview)
        return .sent(preview)
    }
}
