//
//  NetworkWire.swift
//  KalsmritikoshNetworkHelper
//
//  O-2 — the wire types shared with the main app. These MUST stay identical to
//  `KalsmritikoshNetworkProtocol` (Routing/Providers/Online/NetworkHelperClient.swift)
//  and `OutboundHTTPRequest` / `OutboundHTTPResponse`
//  (Routing/Providers/Online/OnlineProviderKind.swift): NSXPC matches the
//  protocol by name and selector; the payloads are JSON with these field names.
//

import Foundation

@objc(KalsmritikoshNetworkProtocol) protocol KalsmritikoshNetworkProtocol {
    func send(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. `meta`: the JSON request WITHOUT its body; `body`: the body's
    /// bytes as they are (no base64 inside JSON). Reply: status, body bytes, Retry-After seconds (< 0 = none), error.
    func sendRaw(_ meta: Data, body: Data, reply: @escaping @Sendable (Int, Data?, Double, String?) -> Void)
    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. Stop one request on the shared connection.
    func cancel(_ requestID: String)
}

struct OutboundHTTPRequest: Codable, Sendable {
    let url: String
    let headers: [String: String]
    let body: Data
    /// A8–A10 — "GET" for public-record lookups and web capture; nil = POST (the AI providers).
    var method: String? = nil
    /// A9 — "capture": a page the person asked to capture (any HTTPS host, GET only).
    var purpose: String? = nil
    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. Names the request for `cancel`.
    var requestID: String? = nil
}

struct OutboundHTTPResponse: Codable, Sendable {
    let status: Int
    let body: Data
    /// Speed PERF-21 (owner 2026-11-23) — not tested yet.
    var retryAfter: Double? = nil
}
