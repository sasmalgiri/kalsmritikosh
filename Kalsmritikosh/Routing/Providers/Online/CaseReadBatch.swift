//
//  CaseReadBatch.swift
//  Kalsmritikosh
//
//  Unified path AI-24 (owner 2026-11-22) — not tested yet. Background case reads (method review, AI conflict
//  look) through the provider's batch service, at about half the price; questions stay interactive.
//
//  Own key (Anthropic Message Batches): create a one-request batch (POST /v1/messages/batches), poll it (GET
//  /v1/messages/batches/<id>) until it has ended, then fetch its results (GET …/<id>/results, JSON lines) and
//  take the one result by its custom_id. The request is the same case read as the interactive one (same
//  content blocks and cache breakpoint, same effort) WITHOUT server-side fallbacks, which the batch service
//  does not accept. Every step before the send — eligibility, permission, masking, protected identities,
//  the daily limit, the own-key monthly limit, re-clearance, the outbound record — is `readCase`'s; this file
//  is only the transport.
//
//  AI plan (relay): POST /v1/batch/create (the relay reserves the worst case at batch rates) and POST
//  /v1/batch/result (the relay settles on the result, gives back on failure; "in_progress" until it ends).
//
//  The network helper allows GET to the AI hosts only for purpose "batch" (status and results).
//

import Foundation
import os

extension OnlineRequestBuilder {

    /// The custom_id of the single request in a case-read batch.
    static let caseBatchRequestID = "case-read-1"

    /// A batch id as the providers issue them (letters, digits, '_' and '-'); anything else is refused, so
    /// a reply can never steer a later GET to another path.
    static func isBatchID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The Messages body of a case read inside a batch (no `fallbacks`: the batch service rejects it).
    static func caseBatchParams(model: String, prefix: [String], suffix: String, replyTokens: Int, ttl: CaseReadCacheTTL,
                                effort: CaseReadEffort) -> [String: Any] {
        [
            "model": model,
            "max_tokens": anthropicMaxTokens(replyTokens),
            "messages": [["role": "user", "content": caseReadContent(prefix: prefix, suffix: suffix, ttl: ttl)]],
            "output_config": ["effort": effort.rawValue]
        ]
    }

    static func anthropicHeaders(_ apiKey: String) -> [String: String] {
        ["content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }

    /// Create the batch: own key → Anthropic; AI plan → the relay's batch route.
    public static func buildCaseBatchCreate(kind: OnlineProviderKind, model: String, apiKey: String, prefix: [String], suffix: String,
                                            replyTokens: Int, ttl: CaseReadCacheTTL, effort: CaseReadEffort) throws -> OutboundHTTPRequest? {
        let params = caseBatchParams(model: model, prefix: prefix, suffix: suffix, replyTokens: replyTokens, ttl: ttl, effort: effort)
        switch kind {
        case .anthropic:
            let body: [String: Any] = ["requests": [["custom_id": caseBatchRequestID, "params": params]]]
            return OutboundHTTPRequest(url: "https://\(kind.host)/v1/messages/batches", headers: anthropicHeaders(apiKey),
                                       body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        case .included:
            var body = params
            body["custom_id"] = caseBatchRequestID
            return try AIIncludedRelay.request("/v1/batch/create", subscription: apiKey, body: body)
        case .openai, .gemini:
            return nil   // no batch path: the read stays interactive
        }
    }

    /// Poll the batch (own key: its status; AI plan: the relay's result route, which answers the result once ended).
    static func buildCaseBatchPoll(kind: OnlineProviderKind, apiKey: String, batchID: String) throws -> OutboundHTTPRequest {
        switch kind {
        case .included:
            return try AIIncludedRelay.request("/v1/batch/result", subscription: apiKey, body: ["batch_id": batchID])
        default:
            return OutboundHTTPRequest(url: "https://\(OnlineProviderKind.anthropic.host)/v1/messages/batches/\(batchID)",
                                       headers: anthropicHeaders(apiKey), body: Data(), method: "GET", purpose: "batch")
        }
    }

    /// Own key: the results of an ended batch (JSON lines).
    static func buildCaseBatchResults(apiKey: String, batchID: String) -> OutboundHTTPRequest {
        OutboundHTTPRequest(url: "https://\(OnlineProviderKind.anthropic.host)/v1/messages/batches/\(batchID)/results",
                            headers: anthropicHeaders(apiKey), body: Data(), method: "GET", purpose: "batch")
    }

    /// Own key: cancel a batch the app stopped waiting for (best effort).
    static func buildCaseBatchCancel(apiKey: String, batchID: String) -> OutboundHTTPRequest {
        OutboundHTTPRequest(url: "https://\(OnlineProviderKind.anthropic.host)/v1/messages/batches/\(batchID)/cancel",
                            headers: anthropicHeaders(apiKey), body: Data())
    }

    public enum BatchError: Error, LocalizedError, Equatable {
        case unreadable, notEnded, failed(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The provider's batch reply could not be read. Nothing was answered."
            case .notEnded:   return "The provider's batch did not finish in time. Nothing was answered; run it again later."
            case .failed(let why): return "The provider's batch did not answer: \(why). Nothing was answered."
            }
        }
    }

    /// The batch id of a create reply.
    static func batchID(_ response: OutboundHTTPResponse) throws -> String {
        guard (200..<300).contains(response.status) else { _ = try parse(kind: .anthropic, response: response); throw BatchError.unreadable }
        guard let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let id = (root["id"] as? String) ?? (root["batch_id"] as? String), isBatchID(id) else { throw BatchError.unreadable }
        return id
    }

    /// Own key: whether a status reply says the batch has ended.
    static func batchEnded(_ response: OutboundHTTPResponse) throws -> Bool {
        guard (200..<300).contains(response.status) else { _ = try parse(kind: .anthropic, response: response); throw BatchError.unreadable }
        guard let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { throw BatchError.unreadable }
        return (root["processing_status"] as? String) == "ended"
    }

    /// Own key: the one request's message from the results (JSON lines), as a Messages response the ordinary
    /// parser and usage reader take.
    static func batchMessage(_ results: OutboundHTTPResponse) throws -> OutboundHTTPResponse {
        guard (200..<300).contains(results.status) else { _ = try parse(kind: .anthropic, response: results); throw BatchError.unreadable }
        let lines = String(decoding: results.body, as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  (obj["custom_id"] as? String) == caseBatchRequestID,
                  let result = obj["result"] as? [String: Any] else { continue }
            let type = result["type"] as? String ?? ""
            guard type == "succeeded", let message = result["message"] as? [String: Any] else {
                let why = ((result["error"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                    ?? ((result["error"] as? [String: Any])?["message"] as? String) ?? type
                throw BatchError.failed(String(why.prefix(200)))
            }
            return OutboundHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: message))
        }
        throw BatchError.unreadable
    }

    /// AI plan: the relay's result reply — nil while the batch is still running, else the Messages response.
    static func relayBatchResult(_ response: OutboundHTTPResponse) throws -> OutboundHTTPResponse? {
        if response.status == 202 { return nil }
        if response.status >= 400 { return response }   // the ordinary parser reads the relay's refusal
        guard let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { throw BatchError.unreadable }
        if let status = root["processing_status"] as? String, status != "ended", root["content"] == nil { return nil }
        return response
    }
}

extension OnlineCloudProvider {
    /// How long a background batch read is waited for in-task (most batches end within an hour), and how often it is
    /// asked. Unified path AI-39 (owner 2026-11-22, round 2) — not tested yet: with the batch journal, a batch not
    /// ended by then is NOT cancelled; it stays recorded, polling resumes at launch, and its result is kept.
    static let caseBatchDeadline: Duration = .seconds(3_600)
    static let caseBatchPollInterval: Duration = .seconds(20)
    static let resumePollInterval: Duration = .seconds(60)

    /// Unified path AI-39 (owner 2026-11-22, round 2) — not tested yet. What the journal needs to record a batch.
    struct BatchContext: Sendable {
        let caseID: UUID
        let purpose: String
        let clearanceFingerprint: String
        let requestDigest: String
        let mapping: [String: String]
    }

    /// AI-24 — one case read through the batch service. Returns the Messages response (the caller parses,
    /// tallies and records it exactly as an interactive reply) and the journal row, or nil when this provider has
    /// no batch path (the caller then sends the interactive read). AI-39: with the journal, a batch already
    /// waiting for exactly this request is polled instead of sending a second one.
    func sendCaseBatch(kind: OnlineProviderKind, model: String, apiKey: String, prefix: [String], suffix: String,
                       replyTokens: Int, ttl: CaseReadCacheTTL, effort: CaseReadEffort, context: BatchContext? = nil,
                       transport: @escaping @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse) async throws -> (response: OutboundHTTPResponse, job: UUID?)? {
        let journal = context == nil ? nil : CaseBatchJournal.current
        var id: String
        var jobID: UUID?
        if let journal, let context,
           let waiting = try? await journal.job(caseID: context.caseID, requestDigest: context.requestDigest,
                                                clearanceFingerprint: context.clearanceFingerprint, state: "waiting"),
           waiting.kind == kind.rawValue {
            id = waiting.batchID; jobID = waiting.id
            KalsmritikoshLog.routing.info("case read: batch \(id, privacy: .public) already waiting for this request — polled, not sent again")
        } else {
            guard let create = try OnlineRequestBuilder.buildCaseBatchCreate(kind: kind, model: model, apiKey: apiKey, prefix: prefix, suffix: suffix,
                                                                             replyTokens: replyTokens, ttl: ttl, effort: effort) else { return nil }
            // Speed PERF-22 (owner 2026-11-23) — not tested yet: an overloaded create is asked again (bounded) first.
            let created = try await OnlineRetry.send(kind: kind) { try await Self.withDeadline(Self.caseReadDeadline) { try await transport(create) } }
            if kind == .included, created.status >= 400 { return (created, nil) }   // the relay's refusal, read by the caller
            id = try OnlineRequestBuilder.batchID(created)
            KalsmritikoshLog.routing.info("case read: batch \(id, privacy: .public) created (\(kind.rawValue, privacy: .public))")
            if let journal, let context {
                do {
                    jobID = try await journal.insert(batchID: id, kind: kind.rawValue, model: model, caseID: context.caseID, purpose: context.purpose,
                                                     clearanceFingerprint: context.clearanceFingerprint, requestDigest: context.requestDigest,
                                                     mapping: context.mapping)
                } catch {
                    KalsmritikoshLog.routing.error("case read: batch \(id, privacy: .public) not recorded (it is waited for in-task only): \(String(describing: error), privacy: .public)")
                }
            }
        }
        let started = ContinuousClock.now
        while ContinuousClock.now - started < Self.caseBatchDeadline {
            try await Task.sleep(for: Self.caseBatchPollInterval)
            if let done = try await pollOnce(kind: kind, apiKey: apiKey, batchID: id, transport: transport) { return (done, jobID) }
        }
        // Not ended in time. AI-39: a recorded batch keeps running (resumed at launch, its result kept); an unrecorded
        // own-key batch is cancelled (best effort; the relay expires and refunds its own).
        if jobID == nil, kind == .anthropic {
            do { _ = try await transport(OnlineRequestBuilder.buildCaseBatchCancel(apiKey: apiKey, batchID: id)) } catch {
                KalsmritikoshLog.routing.error("case read: batch \(id, privacy: .public) could not be cancelled: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw OnlineRequestBuilder.BatchError.notEnded
    }

    /// One poll: the Messages response once the batch has ended, nil while it runs.
    func pollOnce(kind: OnlineProviderKind, apiKey: String, batchID: String,
                  transport: @escaping @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse) async throws -> OutboundHTTPResponse? {
        let poll = try OnlineRequestBuilder.buildCaseBatchPoll(kind: kind, apiKey: apiKey, batchID: batchID)
        let status = try await Self.withDeadline(Self.replyDeadline) { try await transport(poll) }
        if kind == .included { return try OnlineRequestBuilder.relayBatchResult(status) }
        guard try OnlineRequestBuilder.batchEnded(status) else { return nil }
        let results = OnlineRequestBuilder.buildCaseBatchResults(apiKey: apiKey, batchID: batchID)
        let body = try await Self.withDeadline(Self.replyDeadline) { try await transport(results) }
        return try OnlineRequestBuilder.batchMessage(body)
    }

    /// Unified path AI-39 (owner 2026-11-22, round 2) — not tested yet. At launch: every recorded batch still waiting
    /// is polled until it ends (or is older than a day: cancelled best effort and marked abandoned). An ended batch's
    /// reply is tallied at the batch price (own key) or its receipt read (AI plan), recorded in the outbound record,
    /// and kept ('done') for the next run of the same read, which uses it instead of sending again.
    public func resumeCaseBatches() async {
        guard let journal = CaseBatchJournal.current else { return }
        let jobs: [AIBatchJobRepository.Job]
        do { jobs = try await journal.waiting() } catch {
            KalsmritikoshLog.routing.error("batch resume: the batch journal is unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        guard !jobs.isEmpty else { return }
        KalsmritikoshLog.routing.info("batch resume: \(jobs.count, privacy: .public) batch read(s) still waiting")
        var open = jobs
        while !open.isEmpty, !Task.isCancelled {
            // Speed PERF-21 (owner 2026-11-23) — not tested yet. One pass over ALL waiting jobs: the settings are read
            // once, the own key asks the provider for every batch's status in ONE list request, and the jobs that need
            // their own request are polled concurrently (a few at a time) instead of one after another.
            let s = seams.settings()
            var still: [AIBatchJobRepository.Job] = []
            var due: [AIBatchJobRepository.Job] = []
            for job in open {
                guard s.kind.rawValue == job.kind, let key = s.apiKey, s.cloudAllowed else { still.append(job); continue }
                if Date().timeIntervalSince(job.createdAt) > AIBatchJobRepository.maxAge {
                    if s.kind == .anthropic {
                        do { _ = try await seams.transport(OnlineRequestBuilder.buildCaseBatchCancel(apiKey: key, batchID: job.batchID)) } catch {
                            KalsmritikoshLog.routing.error("batch resume: \(job.batchID, privacy: .public) could not be cancelled: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    await journal.finish(job.id, state: "abandoned", detail: "not ended within a day")
                    continue
                }
                due.append(job)
            }
            if let key = s.apiKey, !due.isEmpty {
                let statuses = s.kind == .anthropic ? await listBatchStatuses(apiKey: key) : [:]
                let outcomes = await withTaskGroup(of: (AIBatchJobRepository.Job, Bool?).self) { group -> [(AIBatchJobRepository.Job, Bool?)] in
                    var results: [(AIBatchJobRepository.Job, Bool?)] = []
                    var next = 0
                    func add() {
                        guard next < due.count else { return }
                        let job = due[next]; next += 1
                        group.addTask { (job, await self.resumeOne(job, kind: s.kind, apiKey: key, knownStatus: statuses[job.batchID], journal: journal)) }
                    }
                    for _ in 0..<min(Self.resumePollWidth, due.count) { add() }
                    for await r in group { results.append(r); add() }
                    return results
                }
                for (job, waiting) in outcomes {
                    guard let waiting else { return }      // cancelled
                    if waiting { still.append(job) }
                }
            }
            open = still
            if !open.isEmpty {
                do { try await Task.sleep(for: Self.resumePollInterval) } catch { return }
            }
        }
    }

    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. How many waiting batches are polled at once.
    static let resumePollWidth = 4

    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. Own key: every recent batch's processing status from ONE
    /// list request (batch id → status); empty when the list could not be read (each job is then polled by itself).
    func listBatchStatuses(apiKey: String) async -> [String: String] {
        let list = OutboundHTTPRequest(url: "https://\(OnlineProviderKind.anthropic.host)/v1/messages/batches?limit=100",
                                       headers: OnlineRequestBuilder.anthropicHeaders(apiKey), body: Data(), method: "GET", purpose: "batch")
        do {
            let response = try await Self.withDeadline(Self.replyDeadline) { [seams] in try await seams.transport(list) }
            guard (200..<300).contains(response.status),
                  let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
                  let data = root["data"] as? [[String: Any]] else { return [:] }
            var out: [String: String] = [:]
            for b in data {
                if let id = b["id"] as? String, OnlineRequestBuilder.isBatchID(id), let st = b["processing_status"] as? String { out[id] = st }
            }
            return out
        } catch {
            KalsmritikoshLog.routing.notice("batch resume: the batch list could not be read; each batch is polled by itself: \(OnlineFailure.scrubbed(error.localizedDescription), privacy: .public)")
            return [:]
        }
    }

    /// One waiting job: true = still waiting, false = finished (done or failed), nil = cancelled.
    /// `knownStatus`: the own key's status from the list (a running batch is not asked again in this pass).
    private func resumeOne(_ job: AIBatchJobRepository.Job, kind: OnlineProviderKind, apiKey key: String, knownStatus: String?,
                           journal: AIBatchJobRepository) async -> Bool? {
        do {
            let response: OutboundHTTPResponse
            if kind == .anthropic, let knownStatus {
                guard knownStatus == "ended" else { return true }
                let body = try await Self.withDeadline(Self.replyDeadline) { [seams] in
                    try await seams.transport(OnlineRequestBuilder.buildCaseBatchResults(apiKey: key, batchID: job.batchID))
                }
                response = try OnlineRequestBuilder.batchMessage(body)
            } else {
                guard let polled = try await pollOnce(kind: kind, apiKey: key, batchID: job.batchID, transport: seams.transport) else { return true }
                response = polled
            }
            if kind == .included, response.status >= 400, let why = AIIncludedRelay.refusal(in: response.body) {
                throw OnlineRequestBuilder.ParseError.relay(why)
            }
            let text = try OnlineRequestBuilder.parse(kind: kind, response: response)
            if kind == .included { AICreditMeter.recordReceipt(responseBody: response.body) }
            else if kind == .anthropic { seams.ownKeyBatchTally(response.body, job.model) }
            let usage = ((try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any])?["usage"]
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                .map { String(decoding: $0, as: UTF8.self) }
            await journal.finish(job.id, state: "done", resultText: text, usageJSON: usage, detail: "ended after a relaunch")
            await log(kind, job.model, "batch \(job.batchID) result (\(job.purpose))", 0, 0, response.body.count, "sent",
                      "case read \(job.purpose) (batch, result received after a relaunch; kept for the next run) · " + Self.caseMarker(job.caseID))
            return false
        } catch is CancellationError {
            KalsmritikoshLog.routing.info("batch resume: \(job.batchID, privacy: .public) stopped (cancelled)")
            return nil
        } catch {
            KalsmritikoshLog.routing.error("batch resume: \(job.batchID, privacy: .public) failed: \(OnlineFailure.scrubbed(String(describing: error)), privacy: .public)")
            await journal.finish(job.id, state: "failed", detail: String(OnlineFailure.scrubbed(error.localizedDescription).prefix(200)))
            return false
        }
    }
}
