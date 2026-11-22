//
//  KalsmritikoshNetworkHelper.swift
//  KalsmritikoshNetworkHelper (ExtensionKit, no UI)
//
//  O-2 — the ONLY Kalsmritikosh process allowed to open a network connection
//  (its sandbox alone has `network.client`). It does one thing: send an HTTPS
//  POST to an allowlisted AI host (Anthropic, or the publisher's relay) and return the status and body. It
//  keeps no state, stores nothing, logs no content, and refuses any other host,
//  scheme or method. The main app builds the request, shows the user exactly
//  what will be sent, records every send, and only then asks this helper to carry it.
//

import Foundation
import ExtensionFoundation

final class NetworkService: NSObject, KalsmritikoshNetworkProtocol, @unchecked Sendable {
    /// A2 — the publisher's AI Included relay, once deployed. Keep identical to `AIIncludedRelay.host`
    /// (ci/guards/relay-host-match.sh checks the two).
    static let relayHost = ""
    /// Release decisions 2026-11-04: the own key answers with Anthropic only; recordings go to Gemini
    /// through the relay, never from the Mac. Keep identical to `OnlineProviderKind.allowedHosts`.
    static let allowedHosts: Set<String> = Set(["api.anthropic.com", relayHost].filter { !$0.isEmpty })
    /// A8/A10 — public-record sources, read with GET only. Keep identical to `PublicSource.allHosts`.
    static let lookupHosts: Set<String> = ["data-api.ecb.europa.eu", "sanctionslistservice.ofac.treas.gov", "scsanctions.un.org",
                                           "api.gleif.org", "www.courtlistener.com"]
    /// A9 — the most a captured page or a downloaded list may be.
    static let maxResponseBytes = 40 * 1024 * 1024

    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. ONE session for the helper process, shared by every connection
    /// and request (was one per connection): its HTTP/2 connections stay open and requests to a host are multiplexed over
    /// them. Ephemeral (no cookies, no cache on disk); a send without connectivity fails at once instead of waiting.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral          // no cookies, no cache on disk
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 330                 // a whole-case read may take 300 s
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. Requests in flight by the app's request id, so a cancel stops
    /// one request and leaves the others on the shared connection running.
    private static let tasksLock = NSLock()
    nonisolated(unsafe) private static var tasks: [String: URLSessionTask] = [:]

    func send(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let req = try? JSONDecoder().decode(OutboundHTTPRequest.self, from: request) else {
            reply(nil, "Refused: not an allowed HTTPS destination.")
            return
        }
        carry(req, body: req.body) { status, data, retryAfter, error in
            if let error { reply(nil, error); return }
            reply(try? JSONEncoder().encode(OutboundHTTPResponse(status: status, body: data ?? Data(),
                                                                 retryAfter: retryAfter >= 0 ? retryAfter : nil)), nil)
        }
    }

    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. The body travels as raw bytes beside a small JSON header.
    func sendRaw(_ meta: Data, body: Data, reply: @escaping @Sendable (Int, Data?, Double, String?) -> Void) {
        guard let req = try? JSONDecoder().decode(OutboundHTTPRequest.self, from: meta) else {
            reply(0, nil, -1, "Refused: not an allowed HTTPS destination.")
            return
        }
        carry(req, body: body, reply: reply)
    }

    func cancel(_ requestID: String) {
        Self.tasksLock.lock()
        let task = Self.tasks.removeValue(forKey: requestID)
        Self.tasksLock.unlock()
        task?.cancel()
    }

    /// The one path both selectors take: the same allowlist, method rule and size limit as before.
    private func carry(_ req: OutboundHTTPRequest, body: Data, reply: @escaping @Sendable (Int, Data?, Double, String?) -> Void) {
        guard let url = URL(string: req.url), url.scheme == "https", let host = url.host else {
            reply(0, nil, -1, "Refused: not an allowed HTTPS destination.")
            return
        }
        // POST only to the AI hosts; GET only to the public-record hosts, or to a page the person asked
        // to capture. Nothing else.
        let isGet = req.method == "GET"
        // Unified path AI-24 (owner 2026-11-22): GET to an AI host only for a batch's status and results.
        let allowed = isGet ? (Self.lookupHosts.contains(host) || req.purpose == "capture" || (req.purpose == "batch" && Self.allowedHosts.contains(host)))
                            : Self.allowedHosts.contains(host)
        guard allowed, req.method == nil || isGet else {
            reply(0, nil, -1, "Refused: not an allowed HTTPS destination.")
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = isGet ? "GET" : "POST"
        if !isGet { urlRequest.httpBody = body }
        for (k, v) in req.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
        let requestID = req.requestID
        let task = Self.session.dataTask(with: urlRequest) { data, response, error in
            if let requestID { Self.tasksLock.lock(); Self.tasks.removeValue(forKey: requestID); Self.tasksLock.unlock() }
            if let error { reply(0, nil, -1, error.localizedDescription); return }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (data?.count ?? 0) > Self.maxResponseBytes { reply(0, nil, -1, "Refused: the reply is larger than \(Self.maxResponseBytes / 1_048_576) MB."); return }
            reply(status, data ?? Data(), Self.retryAfter(http?.value(forHTTPHeaderField: "Retry-After")) ?? -1, nil)
        }
        if let requestID { Self.tasksLock.lock(); Self.tasks[requestID] = task; Self.tasksLock.unlock() }
        task.resume()
    }

    /// Speed PERF-21 (owner 2026-11-23) — not tested yet. Retry-After as seconds (a number, or an HTTP date).
    static func retryAfter(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let s = Double(value) { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}

/// Bound to the host's extension point, which exists on macOS 26 and later; the host only
/// launches this helper there (NetworkHelperClient).
@available(macOS 26.0, *)
@main
final class KalsmritikoshNetworkHelper: AppExtension {
    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "ecosanskritiinnovation.Kalsmritikosh", name: "network-helper")
    }

    required init() {}

    var configuration: ConnectionHandler {
        ConnectionHandler(onConnection: { connection in
            connection.exportedInterface = NSXPCInterface(with: KalsmritikoshNetworkProtocol.self)
            connection.exportedObject = NetworkService()
            connection.resume()
            return true
        })
    }
}
