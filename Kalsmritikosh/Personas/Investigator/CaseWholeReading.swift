//
//  CaseWholeReading.swift
//  Kalsmritikosh
//
//  Plan A (owner, 2026-11-04) — what InvestigationAnswerService needs to let the person's AI read a
//  whole case: the case's documents, the cloud gate, the reader (only when AI may read documents now),
//  the permission store and the one-per-case consent, and the size limit. Every part is a closure the
//  app injects (AppState) or a test scripts; nil (no plan wired) keeps the service exactly as before.
//

import Foundation
import os

/// What the person is shown before a case's first AI read: exactly what would go, what would not and
/// why, and what the first read costs.
public nonisolated struct CaseReadConsentRequest: Sendable, Identifiable, Equatable {
    public struct Item: Sendable, Equatable, Hashable {
        public let name: String
        public let bytes: Int
        public let reason: String?
        public init(name: String, bytes: Int, reason: String? = nil) { self.name = name; self.bytes = bytes; self.reason = reason }
    }
    public let id: UUID
    public let caseID: UUID
    public let provider: String
    /// The documents that will be sent.
    public let documents: [Item]
    /// Documents of the case that will NOT be sent, each with its reason (privileged, restricted …).
    public let excluded: [Item]
    public let totalBytes: Int
    public let estimatedTokens: Int
    /// Whether the case is read whole (false: too large — the passages most related to each question).
    public let readsWhole: Bool
    /// Credits (plan) or dollars (own key) for the first read.
    public let estimate: String
    /// The document set the permission is pinned to.
    public let fingerprint: String
    public init(id: UUID = UUID(), caseID: UUID, provider: String, documents: [Item], excluded: [Item], totalBytes: Int,
                estimatedTokens: Int, readsWhole: Bool, estimate: String, fingerprint: String) {
        self.id = id; self.caseID = caseID; self.provider = provider; self.documents = documents; self.excluded = excluded
        self.totalBytes = totalBytes; self.estimatedTokens = estimatedTokens; self.readsWhole = readsWhole
        self.estimate = estimate; self.fingerprint = fingerprint
    }
}

public nonisolated struct CaseWholeReading: Sendable {
    /// The documents of these source versions (ledger text, file name), read on this Mac.
    public var documents: @Sendable (Set<UUID>) async throws -> [CaseReader.Document]
    /// The cloud gate (the service binds it to the case's scope).
    public var gate: @Sendable () -> CloudSourceGate?
    /// The reader when the person's AI may read documents now (AI on, Online set up, provider eligible
    /// and confirmed); nil = no AI: Ask returns search results.
    public var reader: @Sendable () async -> CaseReader?
    public var permissions: CaseReadPermissionStore
    /// Show the consent sheet and wait: true = Allow (the permission is then stored), false = Not now.
    public var askConsent: @Sendable (CaseReadConsentRequest) async -> Bool
    /// The most tokens of case text read whole (the plan's limit, or the own-key setting).
    public var wholeCaseLimit: @Sendable () -> Int
    public var providerName: @Sendable () -> String
    /// The estimate line for the first read (caseTokens, questionTokens).
    public var estimate: @Sendable (_ caseTokens: Int, _ questionTokens: Int) -> String
    /// Questions asked from an open case are interactive: the case text is cached for an hour.
    public var questionTTL: CaseReadCacheTTL = .oneHour
    // Case analysis (contradictions, roles, drafts) reuses this cached prefix with its task as the
    // suffix (`analysisRoute` / `readForAnalysis`), at the SAME TTL as questions so the request is
    // byte-identical through the cache breakpoint and the cache is shared.
    // TODO(plan A, batches): route these background reads through the Message Batches API (50% off).
    // Not wired: it needs submit/poll/result handling in the provider and network helper, and a
    // relay route that reserves credits across an asynchronous batch — more than a small change. Until
    // then they are ordinary case reads (one call per analysis kind).
    /// Whether another AI reader (the passage composer) may answer when no whole-case reader is
    /// installed: then the case is answered the way it was before plan A, not as search results.
    public var otherReadersAvailable: @Sendable () async -> Bool = { false }

    public init(documents: @escaping @Sendable (Set<UUID>) async throws -> [CaseReader.Document],
                gate: @escaping @Sendable () -> CloudSourceGate?,
                reader: @escaping @Sendable () async -> CaseReader?,
                permissions: CaseReadPermissionStore,
                askConsent: @escaping @Sendable (CaseReadConsentRequest) async -> Bool,
                wholeCaseLimit: @escaping @Sendable () -> Int = { CaseWholeReading.defaultLimit },
                providerName: @escaping @Sendable () -> String = { "your AI provider" },
                estimate: @escaping @Sendable (Int, Int) -> String = { tokens, _ in "About \(tokens.formatted()) tokens of case text." }) {
        self.documents = documents; self.gate = gate; self.reader = reader; self.permissions = permissions
        self.askConsent = askConsent; self.wholeCaseLimit = wholeCaseLimit; self.providerName = providerName; self.estimate = estimate
    }

    /// AI Included and the own-key default: about 300k tokens read whole; AI Pro: about 800k.
    public static let defaultLimit = 300_000
    public static let proLimit = 800_000

    // MARK: - The prepared case

    public struct Prepared: Sendable {
        public let documents: [CaseReader.Document]
        public let prefix: [String]
        public let tokens: Int
        public let clearance: CloudSourceClearance
        public let fingerprint: String
        public let excluded: [CaseReadConsentRequest.Item]
        public let caseDocuments: Int
        public let fits: Bool
        public let limit: Int
    }

    /// Load, clear and assemble the case. nil: nothing of the case may be sent (no gate, or every
    /// document denied) — the excluded list says why.
    public func prepare(caseID: UUID, versions: Set<UUID>, binding: CloudScopeBinding) async -> (prepared: Prepared?, excluded: [CaseReadConsentRequest.Item]) {
        guard let gate = gate()?.bound(to: binding) else { return (nil, []) }
        let all: [CaseReader.Document]
        do { all = try await documents(versions) } catch {
            KalsmritikoshLog.brain.error("case reading: documents unreadable: \(String(describing: error), privacy: .public)")
            return (nil, [])
        }
        let (clearance, denied) = await gate.clear(all.map(\.objectID), purpose: "case.reading")
        let excluded = all.filter { denied[$0.objectID] != nil }
            .map { CaseReadConsentRequest.Item(name: $0.fileName ?? "a document", bytes: $0.text.utf8.count, reason: denied[$0.objectID]) }
            .sorted { $0.name < $1.name }
        let cleared = all.filter { clearance.clearedObjectIDs.contains($0.objectID) }
        let (docs, duplicates) = CaseReader.prepare(cleared)
        guard !docs.isEmpty else { return (nil, excluded) }
        if duplicates > 0 { KalsmritikoshLog.brain.info("case reading: \(duplicates, privacy: .public) duplicate document(s) sent once") }
        let prefix = CaseReader.prefix(docs)
        let tokens = CaseReader.estimatedTokens(prefix)
        let limit = wholeCaseLimit()
        return (Prepared(documents: docs, prefix: prefix, tokens: tokens, clearance: clearance,
                         fingerprint: CaseReadPermission.fingerprint(caseID: caseID, versions: clearance.versions),
                         excluded: excluded, caseDocuments: all.count, fits: tokens <= limit, limit: limit), excluded)
    }

    /// The permission for this document set: stored → true; otherwise the sheet, once; Allow stores it.
    public func permitted(caseID: UUID, prepared: Prepared, question: String) async -> Bool {
        if permissions.isGranted(caseID: caseID, fingerprint: prepared.fingerprint) { return true }
        let request = CaseReadConsentRequest(
            caseID: caseID, provider: providerName(),
            documents: prepared.documents.map { .init(name: $0.fileName ?? "a document", bytes: $0.text.utf8.count) },
            excluded: prepared.excluded, totalBytes: prepared.prefix.reduce(0) { $0 + $1.utf8.count },
            estimatedTokens: prepared.tokens, readsWhole: prepared.fits,
            estimate: estimate(prepared.fits ? prepared.tokens : min(prepared.tokens, prepared.limit),
                               CaseReader.estimatedTokens([CaseReader.questionSuffix(question)])),
            fingerprint: prepared.fingerprint)
        guard await askConsent(request) else {
            KalsmritikoshLog.brain.info("case reading: the person chose not now — nothing sent")
            return false
        }
        permissions.grant(caseID: caseID, fingerprint: prepared.fingerprint, documentCount: prepared.documents.count)
        return true
    }

    // MARK: - Case analysis on the whole-case path

    /// How a case analysis reads with AI. Analysis never asks for the permission: it uses the one the
    /// person already gave for the case's current documents, or reads passages as before.
    public enum AnalysisRoute: Sendable {
        /// The case fits and its permission is stored: one whole-case read per analysis kind.
        case wholeCase(CaseReader, Prepared)
        /// Read passages (today's path). `permitted`: the case's stored permission covers the passages
        /// of its cleared documents (too large to read whole) — no second per-send preview for them.
        case passages(permitted: CaseReadPermittedSet?, why: String)
    }

    public func analysisRoute(caseID: UUID, versions: Set<UUID>, binding: CloudScopeBinding) async -> AnalysisRoute {
        guard let reader = await reader() else { return .passages(permitted: nil, why: "no whole-case reader") }
        let (prepared, _) = await prepare(caseID: caseID, versions: versions, binding: binding)
        guard let prepared else { return .passages(permitted: nil, why: "nothing of the case may be sent whole") }
        guard permissions.isGranted(caseID: caseID, fingerprint: prepared.fingerprint) else {
            return .passages(permitted: nil, why: "the case's current documents are not allowed yet")
        }
        guard prepared.fits else {
            return .passages(permitted: CaseReadPermittedSet(caseID: caseID, versions: prepared.clearance.versions),
                             why: "the case is too large to read whole (about \(prepared.tokens.formatted()) tokens, the limit is \(prepared.limit.formatted()))")
        }
        return .wholeCase(reader, prepared)
    }

    /// One whole-case analysis read: the case's cached prefix (byte-identical to a question's) and the
    /// analysis task after it.
    public func readForAnalysis(_ reader: CaseReader, _ prepared: Prepared, caseID: UUID, task: String, replyTokens: Int,
                                purpose: String) async throws -> CaseReader.Reply {
        try await reader.send(CaseReadSend(caseID: caseID, prefix: prepared.prefix, suffix: task, replyTokens: replyTokens,
                                           ttl: questionTTL, effort: .high, purpose: purpose, clearance: prepared.clearance))
    }
}
