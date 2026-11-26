//
//  OnlineRetry.swift
//  Kalsmritikosh
//
//  Speed PERF-22 (owner 2026-11-23) — not tested yet. A provider that answers 429 (limiting), 503 or 529 (overloaded)
//  is asked again automatically — a bounded number of times, waiting what its Retry-After asks (else 2 s, 4 s, 8 s
//  with jitter) — before "try again" is ever shown. Every such reply is noted app-wide (AIOverload) so every adaptive
//  loop halves its concurrency. The request is the SAME one already consented to and recorded (a 429/529 means the
//  provider did not process it); a refusal from the AI Included relay (its own limits, credits) is never retried.
//

import Foundation
import os

public nonisolated enum OnlineRetry {
    static let retryableStatuses: Set<Int> = [429, 503, 529]
    static let maxRetries = 3
    static let maxWaitSeconds: Double = 60

    /// Send through `attempt` (one deadline-bounded transport call), retrying overload replies.
    static func send(kind: OnlineProviderKind,
                     _ attempt: @Sendable () async throws -> OutboundHTTPResponse) async throws -> OutboundHTTPResponse {
        var tries = 0
        while true {
            let response = try await attempt()
            guard retryableStatuses.contains(response.status) else { return response }
            // The relay's own refusal (daily limit, credits, capacity) is an answer, not an overload.
            if kind == .included, AIIncludedRelay.refusal(in: response.body) != nil { return response }
            let wait = min(maxWaitSeconds, response.retryAfter ?? (pow(2, Double(tries + 1)) + Double.random(in: 0...1)))
            AIOverload.note(retryAfter: wait)
            guard tries < maxRetries else {
                KalsmritikoshLog.routing.notice("Online retry: HTTP \(response.status, privacy: .public) after \(tries, privacy: .public) automatic retries; reported")
                return response
            }
            tries += 1
            KalsmritikoshLog.routing.info("Online retry: HTTP \(response.status, privacy: .public); asking again in \(wait, privacy: .public) s (retry \(tries, privacy: .public) of \(maxRetries, privacy: .public))")
            try await Task.sleep(for: .milliseconds(Int(wait * 1_000)))
        }
    }
}

// Speed PERF-22 (owner 2026-11-23) — not tested yet. The adaptive loops read these as overloads (halve, wait).
extension OnlineRequestBuilder.ParseError: AIOverloadSignalling {
    public var isOverload: Bool {
        switch self {
        case .rateLimited: return true
        case .server(let code): return code == 503 || code == 529
        default: return false
        }
    }
    public var overloadRetryAfter: Double? { nil }
}

extension OnlineCloudProvider.OnlineError: AIOverloadSignalling {
    public var isOverload: Bool { if case .timedOut = self { return true }; return false }
    public var overloadRetryAfter: Double? { nil }
}
