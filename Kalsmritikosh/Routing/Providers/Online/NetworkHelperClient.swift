//
//  NetworkHelperClient.swift
//  Kalsmritikosh
//
//  O-2 — the main app's side of the network helper. The main app holds NO
//  network entitlement; it hands a fully built, allowlisted HTTPS request to the
//  bundled XPC service `KalsmritikoshNetwork`, which alone may connect.
//
//  `KalsmritikoshNetworkProtocol` below must be compiled into BOTH the app and
//  the helper target (owner step: add this file to the helper's target
//  membership in Xcode — see KalsmritikoshNetwork/README.md).
//

import Foundation

@objc public protocol KalsmritikoshNetworkProtocol {
    /// `request` is a JSON-encoded `OutboundHTTPRequest`. Reply: a JSON-encoded
    /// `OutboundHTTPResponse`, or nil and an error message.
    func send(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

public enum NetworkHelperError: Error, LocalizedError {
    case unavailable, hostNotAllowed(String), failed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable:          return "Online mode is not available in this build (the network helper is missing)."
        case .hostNotAllowed(let h): return "\(h) is not an allowed destination."
        case .failed(let m):        return m
        }
    }
}

public nonisolated enum NetworkHelperClient {

    public static let serviceName = "ecosanskritiinnovation.Kalsmritikosh.KalsmritikoshNetwork"

    public static func send(_ request: OutboundHTTPRequest) async throws -> OutboundHTTPResponse {
        guard ConnectivityMode.onlineAvailableInThisBuild else { throw NetworkHelperError.unavailable }
        guard let host = URL(string: request.url)?.host, OnlineProviderKind.allowedHosts.contains(host),
              request.url.hasPrefix("https://") else {
            throw NetworkHelperError.hostNotAllowed(URL(string: request.url)?.host ?? request.url)
        }
        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: KalsmritikoshNetworkProtocol.self)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate()
                continuation.resume(throwing: NetworkHelperError.failed(error.localizedDescription))
            } as? KalsmritikoshNetworkProtocol
            guard let proxy else {
                connection.invalidate()
                continuation.resume(throwing: NetworkHelperError.unavailable)
                return
            }
            proxy.send(payload) { data, message in
                connection.invalidate()
                if let data, let response = try? JSONDecoder().decode(OutboundHTTPResponse.self, from: data) {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: NetworkHelperError.failed(message ?? "No reply from the network helper."))
                }
            }
        }
    }
}
