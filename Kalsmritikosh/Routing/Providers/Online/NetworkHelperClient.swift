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
        // A7 — cancellation is honoured at every step: nothing is dispatched once the caller cancelled,
        // and a cancel during the request invalidates the helper connection (the helper's own request
        // stops with it). Bytes the helper already sent cannot be withdrawn.
        try Task.checkCancellation()
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .kalsmritikoshNetworkHelper)
        guard let identity = monitor.identities.first else { throw NetworkHelperError.unavailable }
        try Task.checkCancellation()
        let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {}))
        defer { process.invalidate() }
        try Task.checkCancellation()
        let connection = try process.makeXPCConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: KalsmritikoshNetworkProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let call = HelperCall()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The XPC error handler and the reply can both fire (e.g. the helper
                // replies, then the connection drops); resume exactly once.
                guard call.attach(continuation) else { return }   // cancelled before dispatch: nothing sent
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    call.resume(.failure(NetworkHelperError.failed(error.localizedDescription)))
                } as? KalsmritikoshNetworkProtocol
                guard let proxy else {
                    call.resume(.failure(NetworkHelperError.unavailable))
                    return
                }
                proxy.send(payload) { data, message in
                    if let data, let response = try? JSONDecoder().decode(OutboundHTTPResponse.self, from: data) {
                        call.resume(.success(response))
                    } else {
                        call.resume(.failure(NetworkHelperError.failed(message ?? "No reply from the network helper.")))
                    }
                }
            }
        } onCancel: {
            call.cancel()
            connection.invalidate()
        }
    }
}

/// One helper request: resumes its continuation exactly once, from any thread; a cancel that comes
/// before the continuation is attached means the request is never dispatched.
nonisolated final class HelperCall: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OutboundHTTPResponse, Error>?
    private var cancelled = false
    private var done = false

    /// Attach the continuation; false (and resumed with cancellation) when already cancelled.
    func attach(_ c: CheckedContinuation<OutboundHTTPResponse, Error>) -> Bool {
        lock.lock()
        if cancelled { done = true; lock.unlock(); c.resume(throwing: CancellationError()); return false }
        continuation = c
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        resume(.failure(CancellationError()))
    }

    func resume(_ result: Result<OutboundHTTPResponse, Error>) {
        lock.lock()
        guard !done, let c = continuation else { lock.unlock(); return }
        done = true; continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}

