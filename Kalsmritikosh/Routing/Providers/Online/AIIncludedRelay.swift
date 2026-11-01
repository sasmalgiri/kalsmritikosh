//
//  AIIncludedRelay.swift
//  Kalsmritikosh
//
//  A2 (completion mandate 2026-11-01) — the publisher's AI Included service (relay/ in this repo).
//  A subscriber's questions go to it instead of to a provider with their own key; it confirms the
//  subscription with Apple, counts the month's 300 questions and forwards to Claude Opus 5 with the
//  publisher's key. It stores counts only. The subscriber is identified by the App Store
//  original transaction id of the AI Included subscription — no account, name or e-mail.
//
//  Nothing in this file touches the network: like OnlineRequestBuilder it builds requests the
//  network helper sends, and reads what comes back.
//

import Foundation

public nonisolated enum AIIncludedRelay {
    /// The relay's host, set once the publisher has deployed it (relay/README.md). Empty = AI Included
    /// is not offered in this build. Keep identical to `KalsmritikoshNetworkHelper.relayHost`.
    public static let host = ""
    public static var isConfigured: Bool { !host.isEmpty }

    /// The subscriber header the relay reads.
    static let subscriptionHeader = "x-kals-subscription"

    /// A plain App Store transaction number; anything else is never sent.
    static func isValidSubscription(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func request(_ path: String, subscription: String?, body: [String: Any] = [:]) throws -> OutboundHTTPRequest {
        var headers = ["content-type": "application/json"]
        if let subscription {
            guard isValidSubscription(subscription) else { throw RelayError.notSubscribed }
            headers[subscriptionHeader] = subscription
        }
        return OutboundHTTPRequest(url: "https://\(host)\(path)", headers: headers,
                                   body: try JSONSerialization.data(withJSONObject: body))
    }

    /// Questions left and whether the service is paused this month.
    public struct Status: Equatable, Sendable {
        public let monthly: Int
        public let topUps: Int
        public let paused: Bool
        public var total: Int { monthly + topUps }
    }

    public enum RelayError: Error, LocalizedError, Equatable {
        case notConfigured, notSubscribed, refused(String), unreadable
        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "AI Included is not available in this build."
            case .notSubscribed: return "AI Included is not active for this Apple account."
            case .refused(let why): return why
            case .unreadable: return "The AI Included service's reply could not be read. Try again in a minute."
            }
        }
    }

    /// The relay's own refusal (`{"error":{"code","message"}}`), or nil when the body is not one.
    static func refusal(in body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let code = error["code"] as? String,
              ["not-subscribed", "quota-used", "capacity-paused", "too-large", "bad-request", "store-unavailable", "region-unavailable"].contains(code),
              let message = error["message"] as? String else { return nil }
        return message
    }

    static func object(_ response: OutboundHTTPResponse) throws -> [String: Any] {
        if let why = refusal(in: response.body) { throw RelayError.refused(why) }
        guard (200..<300).contains(response.status),
              let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { throw RelayError.unreadable }
        return root
    }

    static func parseStatus(_ response: OutboundHTTPResponse) throws -> Status {
        let root = try object(response)
        guard let remaining = root["remaining"] as? [String: Any],
              let monthly = remaining["monthly"] as? Int, let topUps = remaining["topUps"] as? Int else { throw RelayError.unreadable }
        return Status(monthly: monthly, topUps: topUps, paused: root["paused"] as? Bool ?? false)
    }

    static func parseSellable(_ response: OutboundHTTPResponse) throws -> Bool {
        guard let sellable = try object(response)["sellable"] as? Bool else { throw RelayError.unreadable }
        return sellable
    }

    /// true when this top-up is now on the subscriber's account (credited now, or already credited before).
    static func parseTopUp(_ response: OutboundHTTPResponse) throws -> Bool {
        let root = try object(response)
        return root["credited"] is Bool
    }

    typealias Transport = @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse

    /// The subscriber's questions left this month (one small request carrying only the subscription number).
    public static func status(subscription: String) async throws -> Status {
        try await status(subscription: subscription, transport: { try await NetworkHelperClient.send($0) })
    }
    static func status(subscription: String, transport: Transport) async throws -> Status {
        guard isConfigured else { throw RelayError.notConfigured }
        return try parseStatus(try await transport(try request("/v1/status", subscription: subscription)))
    }

    /// Whether AI Included is offered to new buyers this month (asked only when someone chooses to buy it;
    /// nothing about the person is sent).
    public static func sellable() async throws -> Bool {
        try await sellable(transport: { try await NetworkHelperClient.send($0) })
    }
    static func sellable(transport: Transport) async throws -> Bool {
        guard isConfigured else { throw RelayError.notConfigured }
        return try parseSellable(try await transport(try request("/v1/sellable", subscription: nil)))
    }

    /// Ask the relay to credit a verified 200-question top-up (it re-checks the transaction with Apple).
    public static func creditTopUp(subscription: String, transactionID: String) async throws -> Bool {
        try await creditTopUp(subscription: subscription, transactionID: transactionID, transport: { try await NetworkHelperClient.send($0) })
    }
    static func creditTopUp(subscription: String, transactionID: String, transport: Transport) async throws -> Bool {
        guard isConfigured else { throw RelayError.notConfigured }
        guard isValidSubscription(transactionID) else { throw RelayError.unreadable }
        return try parseTopUp(try await transport(try request("/v1/topup", subscription: subscription, body: ["transactionId": transactionID])))
    }
}
