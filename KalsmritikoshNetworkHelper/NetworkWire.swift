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
}

struct OutboundHTTPRequest: Codable, Sendable {
    let url: String
    let headers: [String: String]
    let body: Data
    /// A8–A10 — "GET" for public-record lookups and web capture; nil = POST (the AI providers).
    var method: String? = nil
    /// A9 — "capture": a page the person asked to capture (any HTTPS host, GET only).
    var purpose: String? = nil
}

struct OutboundHTTPResponse: Codable, Sendable {
    let status: Int
    let body: Data
}
