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
    /// How long a background batch read is waited for (most batches end within an hour), and how often it is asked.
    static let caseBatchDeadline: Duration = .seconds(3_600)
    static let caseBatchPollInterval: Duration = .seconds(20)

    /// AI-24 — one case read through the batch service. Returns the Messages response (the caller parses,
    /// tallies and records it exactly as an interactive reply), or nil when this provider has no batch path
    /// (the caller then sends the interactive read).
    func sendCaseBatch(kind: OnlineProviderKind, model: String, apiKey: String, prefix: [String], suffix: String,
                       replyTokens: Int, ttl: CaseReadCacheTTL, effort: CaseReadEffort,
                       transport: @escaping @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse) async throws -> OutboundHTTPResponse? {
        guard let create = try OnlineRequestBuilder.buildCaseBatchCreate(kind: kind, model: model, apiKey: apiKey, prefix: prefix, suffix: suffix,
                                                                         replyTokens: replyTokens, ttl: ttl, effort: effort) else { return nil }
        let created = try await Self.withDeadline(Self.caseReadDeadline) { try await transport(create) }
        if kind == .included, created.status >= 400 { return created }   // the relay's refusal, read by the caller
        let id = try OnlineRequestBuilder.batchID(created)
        KalsmritikoshLog.routing.info("case read: batch \(id, privacy: .public) created (\(kind.rawValue, privacy: .public))")
        let started = ContinuousClock.now
        while ContinuousClock.now - started < Self.caseBatchDeadline {
            try await Task.sleep(for: Self.caseBatchPollInterval)
            let poll = try OnlineRequestBuilder.buildCaseBatchPoll(kind: kind, apiKey: apiKey, batchID: id)
            let status = try await Self.withDeadline(Self.replyDeadline) { try await transport(poll) }
            if kind == .included {
                if let done = try OnlineRequestBuilder.relayBatchResult(status) { return done }
                continue
            }
            guard try OnlineRequestBuilder.batchEnded(status) else { continue }
            let results = OnlineRequestBuilder.buildCaseBatchResults(apiKey: apiKey, batchID: id)
            let body = try await Self.withDeadline(Self.replyDeadline) { try await transport(results) }
            return try OnlineRequestBuilder.batchMessage(body)
        }
        // Not ended in time: the own-key batch is cancelled (best effort; the relay expires and refunds its own).
        if kind == .anthropic {
            do { _ = try await transport(OnlineRequestBuilder.buildCaseBatchCancel(apiKey: apiKey, batchID: id)) } catch {
                KalsmritikoshLog.routing.error("case read: batch \(id, privacy: .public) could not be cancelled: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw OnlineRequestBuilder.BatchError.notEnded
    }
}
