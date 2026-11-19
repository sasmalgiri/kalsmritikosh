//
//  AIIncludedRelay.swift
//  Kalsmritikosh
//
//  A2 (completion mandate 2026-11-01; plans and credits 2026-11-04) — the publisher's AI relay (relay/
//  in this repo) behind the AI Included and AI Pro plans. A subscriber's requests go to it instead of
//  to a provider with their own key; it confirms the plan with Apple, reserves the request's worst-case
//  cost in credits (1 credit = US$0.01 of Claude cost), forwards to Claude with the publisher's key and
//  charges the actual cost. It stores counts and credits only. The subscriber is identified by the App
//  Store original transaction id of the subscription group — no account, name or e-mail — proven by the
//  StoreKit signed transaction the app sends (SEC-05), which the relay verifies to Apple's root.
//
//  Nothing in this file touches the network: like OnlineRequestBuilder it builds requests the
//  network helper sends, and reads what comes back.
//

import Foundation
import CryptoKit

public nonisolated enum AIIncludedRelay {
    /// The relay's host, set once the publisher has deployed it (relay/README.md). Empty = AI Included
    /// is not offered in this build. Keep identical to `KalsmritikoshNetworkHelper.relayHost`.
    public static let host = ""
    public static var isConfigured: Bool { !activeHost.isEmpty }

    /// The host requests go to. DEBUG builds have a UI-walk launch option that pretends a relay is configured so a walk
    /// can show the AI plans, the per-case permission sheet and the credit meter before the relay is deployed.
    /// The `.invalid` name never resolves (RFC 2606) and the network helper only allows the real relay host,
    /// so nothing leaves the Mac. Compiled out of Release (scripts/release-check-debug-args.sh).
    static var activeHost: String {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-walk-dummy-relay") { return "relay.ui-walk.invalid" }
        // The GUI walk's simulated AI plan (UIWalkSimulatedPlan) shows the AI plans the same way; it sends nothing.
        if UIWalkSimulatedPlan.isActive { return "relay.ui-walk.invalid" }
        #endif
        return host
    }

    /// The subscriber header the relay reads. SEC-05: it carries the AI subscription's StoreKit 2 signed
    /// transaction (JWS), which the relay verifies to Apple's root (relay/src/jws.ts). The bare transaction
    /// number is not a secret (it is on App Store receipts), so it is never sent as a credential and the
    /// relay refuses it. Mirror of SIGNED_TRANSACTION_HEADER in relay/src/jws.ts.
    static let subscriptionHeader = "x-kals-signed-transaction"

    /// A plain App Store transaction number (credit-pack ids; the appAccountToken seed). Never a credential.
    static func isValidSubscription(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The shape of a compact JWS (three base64url parts, bounded) — what StoreKit's `jwsRepresentation`
    /// is. Anything else (a bare number, an API key) is never sent to the relay. Same size bound as the relay.
    static func isValidSignedTransaction(_ jws: String) -> Bool {
        guard jws.utf8.count <= 16_384 else { return false }
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { p in
            !p.isEmpty && p.utf8.allSatisfy { c in
                (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
            }
        }
    }

    /// `subscription` is the AI period's signed transaction (JWS); nil only for the public sellable check.
    static func request(_ path: String, subscription: String?, body: [String: Any] = [:]) throws -> OutboundHTTPRequest {
        var headers = ["content-type": "application/json"]
        if let subscription {
            guard isValidSignedTransaction(subscription) else { throw RelayError.notSubscribed }
            headers[subscriptionHeader] = subscription
        }
        if path == "/v1/messages", confirmedLargeRead { headers[largeReadHeader] = "confirmed" }
        return OutboundHTTPRequest(url: "https://\(activeHost)\(path)", headers: headers,
                                   body: try JSONSerialization.data(withJSONObject: body))
    }

    /// The header that marks a request as a confirmed whole-case read (the relay then allows up to the
    /// plan's case-read limit instead of the per-request limit). Set ONLY inside
    /// `$confirmedLargeRead.withValue(true)`, after the person accepted the estimate.
    static let largeReadHeader = "x-kals-large-read"
    @TaskLocal public static var confirmedLargeRead = false

    /// The appAccountToken a credit pack is bought with for subscription `sub`, so the relay credits it
    /// to that subscription only: SHA-256("kals-credits:" + sub), first 16 bytes in RFC 4122 version-5
    /// layout. Mirror of accountToken in relay/src/policy.ts.
    public static func accountToken(subscription sub: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("kals-credits:\(sub)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The relay's receipt (`kals` in every reply): the plan, the balance and what the request cost.
    public struct Receipt: Equatable, Sendable {
        public var plan: String              // "ai" | "pro"
        public var monthlyCredits: Int
        public var allowanceLeft: Int
        public var topUps: Int
        public var dailyUsed: Int
        public var dailyLimit: Int
        public var perRequestCredits: Int
        public var caseReadCredits: Int
        public var periodEndsAt: Date?
        /// Credits this request was charged (nil for a status check).
        public var charged: Int?
        public var reserved: Int?
        public var balance: Int { allowanceLeft + topUps }
    }

    /// The plan's state and whether the service is paused this month.
    public struct Status: Equatable, Sendable {
        public let receipt: Receipt
        public let paused: Bool
    }

    /// The `kals` receipt in a relay reply body, or nil.
    public static func receipt(in body: Data) -> Receipt? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return receipt(from: root["kals"] as? [String: Any])
    }

    static func receipt(from k: [String: Any]?) -> Receipt? {
        guard let k, let left = k["allowanceLeft"] as? Int, let top = k["topUps"] as? Int else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Receipt(plan: k["plan"] as? String ?? "ai", monthlyCredits: k["monthlyCredits"] as? Int ?? 0,
                       allowanceLeft: left, topUps: top, dailyUsed: k["dailyUsed"] as? Int ?? 0, dailyLimit: k["dailyLimit"] as? Int ?? 0,
                       perRequestCredits: k["perRequestCredits"] as? Int ?? 0, caseReadCredits: k["caseReadCredits"] as? Int ?? 0,
                       periodEndsAt: (k["periodEndsAt"] as? String).flatMap { iso.date(from: $0) },
                       charged: k["charged"] as? Int, reserved: k["reserved"] as? Int)
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

    /// The refusal codes the relay sends (relay/src/policy.ts RefusalCode). `provider-unavailable` (deep dive batch 4): the
    /// provider did not answer after the request was handed to it — the relay's words never say "Nothing was sent" there.
    static let refusalCodes: Set<String> = ["not-subscribed", "credits-used", "daily-limit", "too-costly", "capacity-paused", "too-large",
                                            "bad-request", "store-unavailable", "region-unavailable", "provider-unavailable"]

    /// The relay's own refusal (`{"error":{"code","message"}}`), or nil when the body is not one.
    static func refusal(in body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let code = error["code"] as? String,
              refusalCodes.contains(code),
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
        guard let r = receipt(from: root["kals"] as? [String: Any]) else { throw RelayError.unreadable }
        return Status(receipt: r, paused: root["paused"] as? Bool ?? false)
    }

    static func parseSellable(_ response: OutboundHTTPResponse) throws -> Bool {
        guard let sellable = try object(response)["sellable"] as? Bool else { throw RelayError.unreadable }
        return sellable
    }

    /// What the relay did with a credit pack: on the account (credited now or before), or removed
    /// because Apple reports it refunded. Either way the transaction may be finished.
    public enum TopUpOutcome: Equatable, Sendable { case onAccount, revoked }
    static func parseTopUp(_ response: OutboundHTTPResponse) throws -> TopUpOutcome {
        let root = try object(response)
        if root["revoked"] as? Bool == true { return .revoked }
        guard root["credited"] is Bool else { throw RelayError.unreadable }
        return .onAccount
    }

    typealias Transport = @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse

    /// The subscriber's credits and plan (one small request carrying only the subscription's signed transaction).
    public static func status(subscription: String) async throws -> Status {
        try await status(subscription: subscription, transport: { try await NetworkHelperClient.send($0) })
    }
    static func status(subscription: String, transport: Transport) async throws -> Status {
        guard isConfigured else { throw RelayError.notConfigured }
        return try parseStatus(try await transport(try request("/v1/status", subscription: subscription)))
    }

    /// Whether the AI plans are offered to new buyers this month (asked only when someone chooses to buy it;
    /// nothing about the person is sent).
    public static func sellable() async throws -> Bool {
        try await sellable(transport: { try await NetworkHelperClient.send($0) })
    }
    static func sellable(transport: Transport) async throws -> Bool {
        guard isConfigured else { throw RelayError.notConfigured }
        return try parseSellable(try await transport(try request("/v1/sellable", subscription: nil)))
    }

    /// Ask the relay to credit a verified credit pack, or to remove a refunded one (it re-checks the
    /// transaction with Apple either way).
    public static func creditTopUp(subscription: String, transactionID: String) async throws -> TopUpOutcome {
        try await creditTopUp(subscription: subscription, transactionID: transactionID, transport: { try await NetworkHelperClient.send($0) })
    }
    static func creditTopUp(subscription: String, transactionID: String, transport: Transport) async throws -> TopUpOutcome {
        guard isConfigured else { throw RelayError.notConfigured }
        guard isValidSubscription(transactionID) else { throw RelayError.unreadable }
        return try parseTopUp(try await transport(try request("/v1/topup", subscription: subscription, body: ["transactionId": transactionID])))
    }
}
