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
}

struct OutboundHTTPResponse: Codable, Sendable {
    let status: Int
    let body: Data
}
