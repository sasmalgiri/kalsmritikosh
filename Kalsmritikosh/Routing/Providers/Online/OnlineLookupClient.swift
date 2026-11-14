//
//  OnlineLookupClient.swift
//  Kalsmritikosh
//
//  A8–A10 — sends public-record lookups and web captures, Online mode only. Anything that carries the
//  person's input (a name, an amount's currency and date, a page address) is previewed and waits for
//  consent; every request is recorded in the outbound log BEFORE it leaves, then completed with its
//  outcome — the same discipline as the AI sends. The sanctions lists carry nothing of the person's
//  (a fixed download), so they are recorded but not previewed, and matching happens on this Mac.
//

import Foundation
import CryptoKit
import os

public actor OnlineLookupClient {
    public struct Seams: Sendable {
        public var online: @Sendable () -> Bool
        public var consent: @Sendable (OutboundPreview) async -> Bool
        public var transport: @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse
        public var now: @Sendable () -> Date
        public init(online: @escaping @Sendable () -> Bool, consent: @escaping @Sendable (OutboundPreview) async -> Bool,
                    transport: @escaping @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse,
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.online = online; self.consent = consent; self.transport = transport; self.now = now
        }
        public static let live = Seams(online: { ConnectivityMode.current == .online },
                                       consent: { await OutboundConsent.shared.request($0) },
                                       transport: { try await NetworkHelperClient.send($0) })
    }

    public enum LookupError: Error, LocalizedError, Equatable {
        case offline, declined, logUnavailable, http(Int), notHTTPS
        public var errorDescription: String? {
            switch self {
            case .offline: return "This needs Online mode (Settings ▸ Modules). Nothing was sent."
            case .declined: return "You chose not to send this. Nothing was sent."
            case .logUnavailable: return "Not sent: the record of what leaves this Mac could not be written."
            case .http(let s): return "The source answered with HTTP \(s). Nothing was added."
            case .notHTTPS: return "Only https:// pages can be captured."
            }
        }
    }

    private let outboundLog: OutboundLogRepository?
    private let seams: Seams
    /// Where downloaded sanctions lists are kept (re-downloaded after a day).
    private let listFolder: URL?

    public init(outboundLog: OutboundLogRepository?, listFolder: URL?, seams: Seams = .live) {
        self.outboundLog = outboundLog; self.listFolder = listFolder; self.seams = seams
    }

    /// Record, (preview), send, record the outcome.
    func send(_ request: OutboundHTTPRequest, label: String, host: String, shown: String, preview: Bool) async throws -> OutboundHTTPResponse {
        guard seams.online() else { throw LookupError.offline }
        if preview {
            let p = OutboundPreview(provider: label, model: "public lookup", host: host, text: shown, bytes: shown.utf8.count, maskedCount: 0)
            guard await seams.consent(p) else { await log(label, host, shown, nil, "declined", nil); throw LookupError.declined }
        }
        guard let outboundLog else { throw LookupError.logUnavailable }
        do {
            try await outboundLog.record(entry(label, host, shown, nil, "sending", nil))
        } catch { throw LookupError.logUnavailable }
        do {
            let r = try await seams.transport(request)
            await log(label, host, shown, r.body.count, (200..<300).contains(r.status) ? "sent" : "failed", "HTTP \(r.status)")
            guard (200..<300).contains(r.status) else { throw LookupError.http(r.status) }
            return r
        } catch let e as LookupError { throw e } catch {
            await log(label, host, shown, nil, "failed", error.localizedDescription)
            throw error
        }
    }

    // MARK: A10

    public struct Conversion: Equatable, Sendable {
        public let amount: Decimal, from: String, to: String, result: Decimal
        public let fromRate: ExchangeRates.Rate?, toRate: ExchangeRates.Rate?
        public let retrievedAt: Date
        /// The citation an investigator can put in a report.
        public var citation: String {
            let used = [fromRate, toRate].compactMap { $0 }.map { "1 EUR = \($0.perEuro) \($0.currency) on \($0.observedOn)" }.joined(separator: "; ")
            return "ECB euro foreign exchange reference rates (\(used.isEmpty ? "EUR only" : used)), retrieved \(ISO8601DateFormatter().string(from: retrievedAt))."
        }
    }

    public func convert(_ amount: Decimal, from: String, to: String, on date: String) async throws -> Conversion {
        func rate(_ c: String) async throws -> ExchangeRates.Rate? {
            guard c != "EUR" else { return nil }
            let req = try ExchangeRates.request(currency: c, date: date)
            let r = try await send(req, label: PublicSource.ecbRates.displayName, host: PublicSource.ecbRates.host,
                                   shown: "Reference rate of \(c) per euro for the week up to \(date).\n\(req.url)", preview: true)
            return try ExchangeRates.parse(r.body, currency: c, date: date)
        }
        let f = from.uppercased(), t = to.uppercased()
        let fr = try await rate(f), tr = try await rate(t)
        return Conversion(amount: amount, from: f, to: t, result: ExchangeRates.convert(amount, from: fr, to: tr),
                          fromRate: fr, toRate: tr, retrievedAt: seams.now())
    }

    // MARK: A8 sanctions

    public struct SanctionsResult: Equatable, Sendable {
        public let matches: [SanctionsLists.Match]
        /// When each list was downloaded.
        public let listDates: [PublicSource: Date]
    }

    public func checkSanctions(_ name: String) async throws -> SanctionsResult {
        var entries: [SanctionsLists.Entry] = []
        var dates: [PublicSource: Date] = [:]
        for (source, req) in SanctionsLists.requests() {
            let (data, at) = try await list(source, req)
            dates[source] = at
            switch source {
            case .ofacSDN: entries += SanctionsLists.parseSDN(data)
            case .ofacAliases: entries += SanctionsLists.parseAliases(data)
            default: entries += SanctionsLists.parseUN(data)
            }
        }
        return SanctionsResult(matches: SanctionsLists.match(name, in: entries), listDates: dates)
    }

    /// A list from the cache when under a day old; otherwise downloaded (nothing of the person's is sent).
    private func list(_ source: PublicSource, _ req: OutboundHTTPRequest) async throws -> (Data, Date) {
        let file = listFolder?.appendingPathComponent("\(source.rawValue).data")
        if let file, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date, seams.now().timeIntervalSince(modified) < 86_400,
           let data = try? Data(contentsOf: file) { return (data, modified) }
        let r = try await send(req, label: source.displayName, host: source.host,
                               shown: "Download of the complete public list (no name is sent; matching happens on this Mac).\n\(req.url)", preview: false)
        if let file {
            do { try r.body.write(to: file, options: .atomic) } catch {
                KalsmritikoshLog.routing.error("Sanctions list cache write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (r.body, seams.now())
    }

    // MARK: A8 registry and courts

    public func searchRegistry(_ name: String) async throws -> [RegistryLookups.Record] {
        let req = RegistryLookups.gleifRequest(name)
        let r = try await send(req, label: PublicSource.gleif.displayName, host: PublicSource.gleif.host,
                               shown: "Search for the company name “\(name)”.\n\(req.url)", preview: true)
        return RegistryLookups.parseGLEIF(r.body)
    }

    public func searchCourts(_ name: String) async throws -> [RegistryLookups.Record] {
        let req = RegistryLookups.courtRequest(name)
        let r = try await send(req, label: PublicSource.courtListener.displayName, host: PublicSource.courtListener.host,
                               shown: "Search US court opinions for the exact phrase “\(name)”.\n\(req.url)", preview: true)
        return RegistryLookups.parseCourts(r.body)
    }

    // MARK: A9 web capture

    public struct Capture: Equatable, Sendable {
        public let url: String, status: Int, body: Data, sha256: String, capturedAt: Date
    }

    public func capture(_ address: String) async throws -> Capture {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme == "https", let host = url.host else { throw LookupError.notHTTPS }
        let req = OutboundHTTPRequest(url: url.absoluteString, headers: ["accept": "text/html,application/xhtml+xml,*/*"], body: Data(),
                                      method: "GET", purpose: "capture")
        let r = try await send(req, label: "Web capture", host: host,
                               shown: "Capture the page \(url.absoluteString) as it is now (the site sees an ordinary request from this Mac's network).", preview: true)
        return Capture(url: url.absoluteString, status: r.status, body: r.body,
                       sha256: SHA256.hash(data: r.body).map { String(format: "%02x", $0) }.joined(), capturedAt: seams.now())
    }

    // MARK: log

    private func entry(_ label: String, _ host: String, _ text: String, _ responseBytes: Int?, _ outcome: String, _ detail: String?) -> OutboundLogEntry {
        OutboundLogEntry(id: UUID(), sentAt: seams.now(), provider: "lookup", model: label, host: host,
                         bytesSent: outcome == "declined" ? 0 : text.utf8.count, maskedCount: 0,
                         payloadSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                         payloadText: text, responseBytes: responseBytes, outcome: outcome, detail: detail)
    }

    private func log(_ label: String, _ host: String, _ text: String, _ responseBytes: Int?, _ outcome: String, _ detail: String?) async {
        guard let outboundLog else { return }
        do { try await outboundLog.record(entry(label, host, text, responseBytes, outcome, detail)) } catch {
            KalsmritikoshLog.routing.error("Outbound log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
