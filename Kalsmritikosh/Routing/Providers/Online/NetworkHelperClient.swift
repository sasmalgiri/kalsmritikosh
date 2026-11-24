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
    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. `meta`: the JSON request without its body; `body`: the body's
    /// bytes as they are (no base64 inside JSON, both ways). Reply: status, body, Retry-After seconds (< 0 = none), error.
    func sendRaw(_ meta: Data, body: Data, reply: @escaping @Sendable (Int, Data?, Double, String?) -> Void)
    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. Stop one request on the shared connection.
    func cancel(_ requestID: String)
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
        // ALCOA ALC-12 — an RFC 3161 timestamp request goes only to the time-stamping authority the person named in
        // Settings, only while timestamping is on (a POST; the helper also checks its type and size).
        if purpose == "timestamp" { return method == nil && TrustedTimestampSettings.allowedHost() == host }
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
        // Speed PERF-21 (owner 2026-11-23) — not tested yet. Only the small header is JSON; the body goes as raw bytes.
        var meta = OutboundHTTPRequest(url: request.url, headers: request.headers, body: Data(),
                                       method: request.method, purpose: request.purpose)
        meta.requestID = UUID().uuidString
        let metaData: Data
        do { metaData = try JSONEncoder().encode(meta) } catch { throw DoorRefusal(underlying: error) }
        guard #available(macOS 26.0, *) else { throw DoorRefusal(underlying: NetworkHelperError.unavailable) }
        NetworkObservation.note(url: request.url, method: request.method, purpose: request.purpose, outcome: .handedToHelper)
        return try await sendViaHelper(meta: metaData, requestID: meta.requestID ?? "", body: request.body, original: request)
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
        // ALCOA ALC-12 — a timestamp request carries a SHA-256 and a nonce only: its own content type, a small body.
        if request.purpose == "timestamp" {
            guard request.headers["Content-Type"] == "application/timestamp-query", request.body.count <= NetworkHelperClient.timestampMaxBody else {
                throw NetworkHelperError.hostNotAllowed(host)
            }
        }
    }

    /// ALCOA ALC-12 — the largest timestamp request (a TimeStampReq over a SHA-256 is about 60 bytes). Keep identical to the helper.
    static let timestampMaxBody = 256

    @available(macOS 26.0, *)
    private static func sendViaHelper(meta: Data, requestID: String, body: Data, original: OutboundHTTPRequest) async throws -> OutboundHTTPResponse {
        // A7 — cancellation is honoured at every step: nothing is dispatched once the caller cancelled,
        // and a cancel during the request stops that request in the helper (Speed PERF-21: by its id, so the
        // other requests on the shared connection keep going). Bytes the helper already sent cannot be withdrawn.
        try Task.checkCancellation()
        #if DEBUG
        NetworkHelperDebugCounters.noteRequest()
        if let standIn = NetworkHelperDebugCounters.standIn {
            // Speed PERF-21 (owner 2026-11-23) — not tested yet. The stand-in takes the place of the helper process and
            // its XPC connection; like the real link, one of each is counted when the session's link is made, not per request.
            NetworkHelperDebugCounters.noteStandInLinkIfNeeded()
            let payload: Data
            do { payload = try JSONEncoder().encode(original) } catch {
                KalsmritikoshLog.routing.error("Network door: stand-in payload not encodable: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            return try await standIn(payload)
        }
        #endif
        // Speed PERF-21 (owner 2026-11-23) — not tested yet. ONE helper process + XPC connection for the app session
        // (NetworkHelperLink), made on first use, remade after an interruption or invalidation, closed when idle.
        let link = try await NetworkHelperLink.shared.current()
        try Task.checkCancellation()
        let call = HelperCall()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The XPC error handler and the reply can both fire (e.g. the helper
                // replies, then the connection drops); resume exactly once.
                guard call.attach(continuation) else { return }   // cancelled before dispatch: nothing sent
                let proxy = link.connection.remoteObjectProxyWithErrorHandler { error in
                    KalsmritikoshLog.routing.notice("Network helper link: XPC error, the link is remade on the next send: \(error.localizedDescription, privacy: .public)")
                    Task { await NetworkHelperLink.shared.drop(link) }
                    call.resume(.failure(NetworkHelperError.failed(error.localizedDescription)))
                } as? KalsmritikoshNetworkProtocol
                guard let proxy else {
                    call.resume(.failure(NetworkHelperError.unavailable))
                    return
                }
                link.begin()
                proxy.sendRaw(meta, body: body) { status, data, retryAfter, message in
                    link.end()
                    if let message {
                        call.resume(.failure(NetworkHelperError.failed(message)))
                    } else if status > 0 {
                        call.resume(.success(OutboundHTTPResponse(status: status, body: data ?? Data(),
                                                                  retryAfter: retryAfter >= 0 ? retryAfter : nil)))
                    } else {
                        call.resume(.failure(NetworkHelperError.failed("No reply from the network helper.")))
                    }
                }
            }
        } onCancel: {
            call.cancel()
            // Speed PERF-21 (owner 2026-11-23) — not tested yet: stop THIS request in the helper, not the shared link.
            (link.connection.remoteObjectProxy as? KalsmritikoshNetworkProtocol)?.cancel(requestID)
        }
    }
}

/// Speed PERF-21 (owner 2026-11-23) — not tested yet. The one helper process and XPC connection the app keeps for its
/// session (was one of each per request). Made on first use; dropped when the helper is interrupted, the connection is
/// invalidated or an XPC error is seen, and remade on the next send; closed after `idleTimeout` with nothing in flight.
/// The helper stays the ONLY door to the network; every check before it (NetworkHelperClient.checkDoor) is unchanged.
@available(macOS 26.0, *)
actor NetworkHelperLink {
    static let shared = NetworkHelperLink()
    static let idleTimeout: Duration = .seconds(180)

    /// One live process + connection. NSXPCConnection is thread-safe; the box only carries it across isolation.
    final class Link: @unchecked Sendable {
        let process: AppExtensionProcess
        let connection: NSXPCConnection
        private let lock = NSLock()
        private var inFlight = 0
        private var lastUsed = ContinuousClock.now
        init(process: AppExtensionProcess, connection: NSXPCConnection) { self.process = process; self.connection = connection }
        func begin() { lock.lock(); inFlight += 1; lastUsed = .now; lock.unlock() }
        func end() { lock.lock(); inFlight = max(0, inFlight - 1); lastUsed = .now; lock.unlock() }
        var idleSince: ContinuousClock.Instant? { lock.lock(); defer { lock.unlock() }; return inFlight == 0 ? lastUsed : nil }
        func close() { connection.invalidate(); process.invalidate() }
    }

    private var link: Link?
    private var making: Task<Link, Error>?
    private var idleWatch: Task<Void, Never>?

    /// The live link, or a new one (concurrent first sends share one launch).
    func current() async throws -> Link {
        if let link { return link }
        if let making { return try await making.value }
        let task = Task { try await Self.make() }
        making = task
        defer { making = nil }
        do {
            let made = try await task.value
            link = made
            watchIdle()
            return made
        } catch {
            KalsmritikoshLog.routing.error("Network helper link: could not start the helper: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Forget a link that failed (only if it is still the current one); the next send makes a new one.
    func drop(_ failed: Link) {
        guard link === failed else { return }
        link = nil
        failed.close()
    }

    private static func make() async throws -> Link {
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .kalsmritikoshNetworkHelper)
        guard let identity = monitor.identities.first else { throw NetworkHelperError.unavailable }
        // The handlers drop exactly the link they belong to (never a newer one made after it).
        let ref = LinkRef()
        let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {
            KalsmritikoshLog.routing.notice("Network helper link: the helper was interrupted; the link is remade on the next send")
            ref.dropLater()
        }))
        #if DEBUG
        NetworkHelperDebugCounters.noteLaunch()
        #endif
        let connection: NSXPCConnection
        do { connection = try process.makeXPCConnection() } catch {
            KalsmritikoshLog.routing.error("Network helper link: no XPC connection: \(error.localizedDescription, privacy: .public)")
            process.invalidate()
            throw error
        }
        #if DEBUG
        NetworkHelperDebugCounters.noteConnection()
        #endif
        connection.remoteObjectInterface = NSXPCInterface(with: KalsmritikoshNetworkProtocol.self)
        connection.invalidationHandler = { ref.dropLater() }
        connection.interruptionHandler = { ref.dropLater() }
        let made = Link(process: process, connection: connection)
        ref.set(made)
        connection.resume()
        return made
    }

    /// Points a handler at its own link without keeping it alive.
    final class LinkRef: @unchecked Sendable {
        private let lock = NSLock()
        private weak var link: Link?
        func set(_ l: Link) { lock.lock(); link = l; lock.unlock() }
        func dropLater() {
            lock.lock(); let l = link; lock.unlock()
            guard let l else { return }
            Task { await NetworkHelperLink.shared.drop(l) }
        }
    }

    /// Close the link once it has been idle (nothing in flight) for `idleTimeout`.
    private func watchIdle() {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                if await self.closeIfIdle() { return }
            }
        }
    }

    private func closeIfIdle() -> Bool {
        guard let l = link else { return true }
        guard let since = l.idleSince, ContinuousClock.now - since >= Self.idleTimeout else { return false }
        link = nil
        l.close()
        KalsmritikoshLog.routing.info("Network helper link: closed after being idle")
        return true
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
    public static func setStandIn(_ s: StandIn?) { standInLock.withLock { $0 = s }; standInLinked.withLock { $0 = false } }
    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. The stand-in's "link": one launch + connection per stand-in session.
    private static let standInLinked = OSAllocatedUnfairLock(initialState: false)
    static func noteStandInLinkIfNeeded() {
        let first = standInLinked.withLock { linked -> Bool in defer { linked = true }; return !linked }
        if first { noteLaunch(); noteConnection() }
    }
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

