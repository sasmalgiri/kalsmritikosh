//
//  NetworkHelperClient.swift
//  Kalsmritikosh
//
//  O-2 — the main app's side of the network helper. The main app holds NO
//  network entitlement; it hands a fully built, allowlisted HTTPS request to the
//  embedded ExtensionKit helper `KalsmritikoshNetworkHelper` (its own sandboxed
//  process, the only one with `network.client`), which alone may connect.
//
//  The app declares the `network-helper` extension point (inside-the-app scope
//  only); the helper binds to it. The wire protocol is mirrored in
//  KalsmritikoshNetworkHelper/NetworkWire.swift — keep the two identical.
//

import Foundation
import ExtensionFoundation

@available(macOS 26.0, *)
extension AppExtensionPoint {
    /// O-2 — the network helper's extension point. Default scope: only extensions inside this app may bind.
    @Definition
    static var kalsmritikoshNetworkHelper: AppExtensionPoint {
        Name("network-helper")
        UserInterface(false)
    }
}

@objc(KalsmritikoshNetworkProtocol) public protocol KalsmritikoshNetworkProtocol {
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

    public static func send(_ request: OutboundHTTPRequest) async throws -> OutboundHTTPResponse {
        guard ConnectivityMode.onlineAvailableInThisBuild else { throw NetworkHelperError.unavailable }
        guard let host = URL(string: request.url)?.host, OnlineProviderKind.allowedHosts.contains(host),
              request.url.hasPrefix("https://") else {
            throw NetworkHelperError.hostNotAllowed(URL(string: request.url)?.host ?? request.url)
        }
        let payload = try JSONEncoder().encode(request)
        guard #available(macOS 26.0, *) else { throw NetworkHelperError.unavailable }
        return try await sendViaHelper(payload)
    }

    @available(macOS 26.0, *)
    private static func sendViaHelper(_ payload: Data) async throws -> OutboundHTTPResponse {
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .kalsmritikoshNetworkHelper)
        guard let identity = monitor.identities.first else { throw NetworkHelperError.unavailable }
        let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {}))
        defer { process.invalidate() }
        let connection = try process.makeXPCConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: KalsmritikoshNetworkProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            // The XPC error handler and the reply can both fire (e.g. the helper
            // replies, then the connection drops); resume exactly once.
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(NetworkHelperError.failed(error.localizedDescription)))
            } as? KalsmritikoshNetworkProtocol
            guard let proxy else {
                once.resume(.failure(NetworkHelperError.unavailable))
                return
            }
            proxy.send(payload) { data, message in
                if let data, let response = try? JSONDecoder().decode(OutboundHTTPResponse.self, from: data) {
                    once.resume(.success(response))
                } else {
                    once.resume(.failure(NetworkHelperError.failed(message ?? "No reply from the network helper.")))
                }
            }
        }
    }
}

/// Resumes a checked continuation at most once, from any thread.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OutboundHTTPResponse, Error>?

    init(_ continuation: CheckedContinuation<OutboundHTTPResponse, Error>) { self.continuation = continuation }

    func resume(_ result: Result<OutboundHTTPResponse, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
