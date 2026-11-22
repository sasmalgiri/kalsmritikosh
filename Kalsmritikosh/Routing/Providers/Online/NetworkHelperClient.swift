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
import os

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

    /// The same rule the helper applies: POST to the AI hosts only; GET to the public-record hosts, or to
    /// a page the person asked to capture.
    static func allows(host: String, method: String?, purpose: String?) -> Bool {
        switch method {
        case nil: return OnlineProviderKind.allowedHosts.contains(host)
        // Unified path AI-24 (owner 2026-11-22): GET to an AI host only for a batch's status and results.
        case "GET": return PublicSource.allHosts.contains(host) || purpose == "capture"
            || (purpose == "batch" && OnlineProviderKind.allowedHosts.contains(host))
        default: return false
        }
    }

    public static func send(_ request: OutboundHTTPRequest) async throws -> OutboundHTTPResponse {
        // R2-E (SEC-09) — every attempt is noted at this one door when an observation session records (content-free).
        do {
            return try await sendThroughDoor(request)
        } catch let refusal as DoorRefusal {
            NetworkObservation.note(url: request.url, method: request.method, purpose: request.purpose, outcome: .refusedBeforeLeaving)
            KalsmritikoshLog.routing.notice("Network door: refused before leaving: \(refusal.underlying.localizedDescription, privacy: .public)")
            throw refusal.underlying
        } catch {
            NetworkObservation.note(url: request.url, method: request.method, purpose: request.purpose, outcome: .failed)
            KalsmritikoshLog.routing.notice("Network door: the helper's send failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// A refusal made before anything was handed to the helper (nothing left this Mac).
    private struct DoorRefusal: Error { let underlying: Error }

    private static func sendThroughDoor(_ request: OutboundHTTPRequest) async throws -> OutboundHTTPResponse {
        do {
            try checkDoor(request)
        } catch {
            throw DoorRefusal(underlying: error)
        }
        let payload: Data
        do { payload = try JSONEncoder().encode(request) } catch { throw DoorRefusal(underlying: error) }
        guard #available(macOS 26.0, *) else { throw DoorRefusal(underlying: NetworkHelperError.unavailable) }
        NetworkObservation.note(url: request.url, method: request.method, purpose: request.purpose, outcome: .handedToHelper)
        return try await sendViaHelper(payload)
    }

    private static func checkDoor(_ request: OutboundHTTPRequest) throws {
        #if DEBUG
        // GUI walk (DEBUG only): a simulated AI plan sends nothing at all, whatever the caller.
        if let refusal = UIWalkSimulatedPlan.dispatchRefusal() {
            KalsmritikoshLog.routing.notice("UI walk simulation: request to \(URL(string: request.url)?.host ?? "?", privacy: .public) refused, nothing sent")
            throw refusal
        }
        #endif
        guard ConnectivityMode.onlineAvailableInThisBuild else { throw NetworkHelperError.unavailable }
        guard let host = URL(string: request.url)?.host, request.url.hasPrefix("https://"),
              Self.allows(host: host, method: request.method, purpose: request.purpose) else {
            throw NetworkHelperError.hostNotAllowed(URL(string: request.url)?.host ?? request.url)
        }
        // A3 — every AI destination (the providers and AI Included) is closed where the App Store
        // country does not allow generative AI; the check sits here so no caller can skip it.
        // Public-record lookups and web capture are not AI and are not affected.
        if OnlineProviderKind.allowedHosts.contains(host), let why = AIRegion.current.explanation { throw NetworkHelperError.failed(why) }
    }

    @available(macOS 26.0, *)
    private static func sendViaHelper(_ payload: Data) async throws -> OutboundHTTPResponse {
        // A7 — cancellation is honoured at every step: nothing is dispatched once the caller cancelled,
        // and a cancel during the request invalidates the helper connection (the helper's own request
        // stops with it). Bytes the helper already sent cannot be withdrawn.
        try Task.checkCancellation()
        #if DEBUG
        NetworkHelperDebugCounters.noteRequest()
        if let standIn = NetworkHelperDebugCounters.standIn {
            // The stand-in takes the place of the helper process and its XPC connection; this function makes one of
            // each per request (below), so one of each is counted here too. PERF-21 must keep the counts where it
            // makes (or reuses) them.
            NetworkHelperDebugCounters.noteLaunch()
            NetworkHelperDebugCounters.noteConnection()
            return try await standIn(payload)
        }
        #endif
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .kalsmritikoshNetworkHelper)
        guard let identity = monitor.identities.first else { throw NetworkHelperError.unavailable }
        try Task.checkCancellation()
        let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {}))
        defer { process.invalidate() }
        #if DEBUG
        NetworkHelperDebugCounters.noteLaunch()
        #endif
        try Task.checkCancellation()
        let connection = try process.makeXPCConnection()
        #if DEBUG
        NetworkHelperDebugCounters.noteConnection()
        #endif
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

#if DEBUG
/// Speed program PERF-33 (owner 2026-11-23) — DEBUG-only counters at the helper door: requests handed to the helper,
/// helper processes started and XPC connections made. The speed benchmark (SpeedBenchmarkTests) reads them before and
/// after PERF-21. `standIn` (benchmarks only) answers in place of the helper process: nothing leaves the Mac.
public nonisolated enum NetworkHelperDebugCounters {
    public struct Snapshot: Sendable, Equatable, Codable {
        public var requests = 0
        public var helperLaunches = 0
        public var connections = 0
    }
    public typealias StandIn = @Sendable (Data) async throws -> OutboundHTTPResponse
    private static let counts = OSAllocatedUnfairLock(initialState: Snapshot())
    private static let standInLock = OSAllocatedUnfairLock<StandIn?>(initialState: nil)

    public static var snapshot: Snapshot { counts.withLock { $0 } }
    public static func reset() { counts.withLock { $0 = Snapshot() } }
    public static var standIn: StandIn? { standInLock.withLock { $0 } }
    public static func setStandIn(_ s: StandIn?) { standInLock.withLock { $0 = s } }
    static func noteRequest() { counts.withLock { $0.requests += 1 } }
    static func noteLaunch() { counts.withLock { $0.helperLaunches += 1 } }
    static func noteConnection() { counts.withLock { $0.connections += 1 } }
}
#endif

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

