//
//  PublicLookups.swift
//  Kalsmritikosh
//
//  A8 / A10 (completion mandate 2026-11-01) — public records an investigator checks by hand today,
//  read in Online mode from free official sources, never through AI:
//
//   • Historical exchange rates — the European Central Bank's reference rates (SDMX API).
//   • Sanctions lists — the US Treasury OFAC SDN list (with aliases) and the UN Security Council
//     consolidated list. The WHOLE lists are downloaded and matched on this Mac, so the names checked
//     never leave it.
//   • Company registry — GLEIF's Legal Entity Identifier records (the name searched is sent; previewed).
//   • Court records — CourtListener's US opinions search (the name searched is sent; previewed).
//
//  A result is a lead with its source and retrieval time, never a finding: a list match on a name is a
//  POSSIBLE match until identifiers agree, and the app says so.
//
//  Like the rest of Routing/Providers/Online, this builds requests and reads replies; the network
//  helper alone sends them (GET, to these hosts only).
//

import Foundation
import os

public nonisolated enum PublicSource: String, CaseIterable, Sendable, Identifiable {
    case ecbRates, ofacSDN, ofacAliases, unConsolidated, gleif, courtListener
    public var id: String { rawValue }

    public var host: String {
        switch self {
        case .ecbRates: return "data-api.ecb.europa.eu"
        case .ofacSDN, .ofacAliases: return "sanctionslistservice.ofac.treas.gov"
        case .unConsolidated: return "scsanctions.un.org"
        case .gleif: return "api.gleif.org"
        case .courtListener: return "www.courtlistener.com"
        }
    }

    public var displayName: String {
        switch self {
        case .ecbRates: return "European Central Bank reference rates"
        case .ofacSDN: return "OFAC Specially Designated Nationals list (US Treasury)"
        case .ofacAliases: return "OFAC SDN aliases (US Treasury)"
        case .unConsolidated: return "UN Security Council consolidated sanctions list"
        case .gleif: return "GLEIF Legal Entity Identifier records"
        case .courtListener: return "CourtListener (Free Law Project) — US court opinions"
        }
    }

    /// Keep identical to `NetworkService.lookupHosts` in the network helper.
    public static let allHosts: Set<String> = Set(allCases.map(\.host))

    static func get(_ url: String) -> OutboundHTTPRequest {
        OutboundHTTPRequest(url: url, headers: ["accept": "*/*"], body: Data(), method: "GET")
    }
}

// MARK: - A10 Exchange rates

public nonisolated enum ExchangeRates {
    public struct Rate: Equatable, Sendable {
        public let currency: String      // per 1 EUR
        public let observedOn: String    // YYYY-MM-DD actually used (the last business day on or before the date)
        public let perEuro: Decimal
    }

    public enum RateError: Error, LocalizedError, Equatable {
        case badCurrency(String), noRate(String, String), unreadable
        public var errorDescription: String? {
            switch self {
            case .badCurrency(let c): return "“\(c)” is not a three-letter currency code."
            case .noRate(let c, let d): return "The ECB published no \(c) reference rate in the week up to \(d)."
            case .unreadable: return "The ECB's reply could not be read."
            }
        }
    }

    static func validCode(_ c: String) -> Bool { c.count == 3 && c.allSatisfy { $0.isASCII && $0.isUppercase } }

    /// The daily reference-rate series of `currency` for the week up to `date` (the ECB does not publish
    /// on weekends and TARGET holidays, so the last rate on or before the date is used and named).
    public static func request(currency: String, date: String) throws -> OutboundHTTPRequest {
        guard validCode(currency) else { throw RateError.badCurrency(currency) }
        let start = Self.day(date, minus: 7) ?? date
        return PublicSource.get("https://\(PublicSource.ecbRates.host)/service/data/EXR/D.\(currency).EUR.SP00.A?startPeriod=\(start)&endPeriod=\(date)&format=csvdata")
    }

    static func day(_ iso: String, minus days: Int) -> String? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: iso) else { return nil }
        return f.string(from: d.addingTimeInterval(-Double(days) * 86_400))
    }

    /// The last observation on or before `date` in an SDMX CSV reply.
    public static func parse(_ csv: Data, currency: String, date: String) throws -> Rate {
        guard let text = String(data: csv, encoding: .utf8) else { throw RateError.unreadable }
        let rows = text.split(whereSeparator: \.isNewline).map { CSV.fields(String($0)) }
        guard let header = rows.first, let t = header.firstIndex(of: "TIME_PERIOD"), let v = header.firstIndex(of: "OBS_VALUE") else {
            throw text.isEmpty ? RateError.noRate(currency, date) : RateError.unreadable
        }
        let obs = rows.dropFirst().compactMap { r -> (String, Decimal)? in
            guard r.count > max(t, v), r[t] <= date, let value = Decimal(string: r[v], locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            return (r[t], value)
        }
        guard let last = obs.max(by: { $0.0 < $1.0 }) else { throw RateError.noRate(currency, date) }
        return Rate(currency: currency, observedOn: last.0, perEuro: last.1)
    }

    /// `amount` in `from` expressed in `to`, through the euro reference rates (EUR itself is 1).
    public static func convert(_ amount: Decimal, from: Rate?, to: Rate?) -> Decimal {
        let fromPerEuro = from?.perEuro ?? 1, toPerEuro = to?.perEuro ?? 1
        var r = amount / fromPerEuro * toPerEuro, out = Decimal()
        NSDecimalRound(&out, &r, 4, .plain)
        return out
    }
}

// MARK: - A8 Sanctions lists (matched on this Mac)

public nonisolated enum SanctionsLists {
    public struct Entry: Equatable, Sendable {
        public let list: PublicSource
        public let reference: String   // OFAC ent_num / UN reference number
        public let name: String
        public let detail: String      // programme / list type
    }

    public struct Match: Equatable, Sendable {
        public let entry: Entry
        public let exact: Bool
    }

    public static func requests() -> [(PublicSource, OutboundHTTPRequest)] {
        [(.ofacSDN, PublicSource.get("https://\(PublicSource.ofacSDN.host)/api/PublicationPreview/exports/SDN.CSV")),
         (.ofacAliases, PublicSource.get("https://\(PublicSource.ofacAliases.host)/api/PublicationPreview/exports/ALT.CSV")),
         (.unConsolidated, PublicSource.get("https://\(PublicSource.unConsolidated.host)/resources/xml/en/consolidated.xml"))]
    }

    /// OFAC SDN.CSV: ent_num, SDN_Name, SDN_Type, Program, … (no header row; "-0-" means empty).
    public static func parseSDN(_ data: Data) -> [Entry] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let f = CSV.fields(String(line))
            guard f.count >= 4, !f[1].isEmpty, f[1] != "-0-" else { return nil }
            return Entry(list: .ofacSDN, reference: f[0], name: f[1], detail: [f[2], f[3]].filter { $0 != "-0-" && !$0.isEmpty }.joined(separator: " · "))
        }
    }

    /// OFAC ALT.CSV: ent_num, alt_num, alt_type, alt_name, alt_remarks.
    public static func parseAliases(_ data: Data) -> [Entry] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let f = CSV.fields(String(line))
            guard f.count >= 4, !f[3].isEmpty, f[3] != "-0-" else { return nil }
            return Entry(list: .ofacSDN, reference: f[0], name: f[3], detail: "alias (\(f[2]))")
        }
    }

    /// UN consolidated XML: INDIVIDUAL and ENTITY records with their names and aliases.
    public static func parseUN(_ data: Data) -> [Entry] {
        let reader = UNListReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.entries
    }

    /// Fold case and accents, keep letters and digits: "Al-Qaida  Ltd." → ["al", "qaida", "ltd"].
    static func tokens(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    /// Entries whose name holds every word of `query`, in any order (exact name first). Never fuzzier than
    /// that: a list check that "finds" everyone is useless, and one that hides a reordered name is worse.
    public static func match(_ query: String, in entries: [Entry], limit: Int = 50) -> [Match] {
        let q = Set(tokens(query))
        guard !q.isEmpty else { return [] }
        var out: [Match] = []
        for e in entries {
            let t = tokens(e.name)
            guard q.isSubset(of: Set(t)) else { continue }
            out.append(Match(entry: e, exact: Set(t) == q))
        }
        return Array(out.sorted { ($0.exact ? 0 : 1, $0.entry.name) < ($1.exact ? 0 : 1, $1.entry.name) }.prefix(limit))
    }
}

/// Speed PERF-29 (owner 2026-11-23) — not tested yet. The lists parsed once into an index (each name's words folded
/// once, an inverted word → entries map) and kept in memory until a list's file on disk changes (its modification date
/// or size). The online check and the local check share it. `match` over the index gives exactly what
/// `SanctionsLists.match` gives over the entries.
public nonisolated final class SanctionsListIndex: Sendable {
    public let entries: [SanctionsLists.Entry]
    let nameTokens: [Set<String>]
    let postings: [String: [Int]]

    public init(_ entries: [SanctionsLists.Entry]) {
        self.entries = entries
        let toks = WorkStealingQueue.mapSync(count: entries.count, workers: WorkStealingQueue.cpuWidth(perItemBytes: 1 << 16)) {
            Set(SanctionsLists.tokens(entries[$0].name))
        }
        var post: [String: [Int]] = [:]
        for (i, t) in toks.enumerated() { for w in t { post[w, default: []].append(i) } }
        nameTokens = toks; postings = post
    }

    public func match(_ query: String, limit: Int = 50) -> [SanctionsLists.Match] {
        let q = Set(SanctionsLists.tokens(query))
        guard !q.isEmpty else { return [] }
        // The rarest word's entries, then the rest of the words checked on each.
        let lists = q.map { postings[$0] ?? [] }
        guard let rarest = lists.min(by: { $0.count < $1.count }) else { return [] }
        var out: [SanctionsLists.Match] = []
        for i in rarest where q.isSubset(of: nameTokens[i]) {
            out.append(SanctionsLists.Match(entry: entries[i], exact: nameTokens[i] == q))
        }
        return Array(out.sorted { ($0.exact ? 0 : 1, $0.entry.name) < ($1.exact ? 0 : 1, $1.entry.name) }.prefix(limit))
    }

    /// One list's entries by its source.
    public static func parse(_ source: PublicSource, _ data: Data) -> [SanctionsLists.Entry] {
        switch source {
        case .ofacSDN: return SanctionsLists.parseSDN(data)
        case .ofacAliases: return SanctionsLists.parseAliases(data)
        default: return SanctionsLists.parseUN(data)
        }
    }
}

/// Speed PERF-29 (owner 2026-11-23) — not tested yet. Parsed lists by source, each with the stamp of the file it came
/// from; a changed file (another modification date or size) is parsed again. Combined indexes are kept per set of stamps.
public nonisolated enum SanctionsListCache {
    private struct Parsed: Sendable { let stamp: String; let entries: [SanctionsLists.Entry] }
    private static let parsed = OSAllocatedUnfairLock<[PublicSource: Parsed]>(initialState: [:])
    private static let combined = OSAllocatedUnfairLock<(key: String, index: SanctionsListIndex)?>(initialState: nil)

    /// The stamp of a list file (nil when it cannot be read).
    public static func stamp(of file: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return "\(modified.timeIntervalSinceReferenceDate)|\((attrs[.size] as? NSNumber)?.int64Value ?? -1)"
    }

    /// A list's entries for `data` under `stamp`, parsed only when the stamp changed.
    public static func entries(_ source: PublicSource, stamp: String?, data: () -> Data?) -> [SanctionsLists.Entry]? {
        if let stamp, let known = parsed.withLock({ $0[source] }), known.stamp == stamp { return known.entries }
        guard let d = data() else { return nil }
        let e = SanctionsListIndex.parse(source, d)
        if let stamp { parsed.withLock { $0[source] = Parsed(stamp: stamp, entries: e) } }
        return e
    }

    /// One index over the given lists (in their order), rebuilt only when one of their stamps changed.
    public static func index(_ lists: [(source: PublicSource, stamp: String?, entries: [SanctionsLists.Entry])]) -> SanctionsListIndex {
        let stamps = lists.map { "\($0.source.rawValue)=\($0.stamp ?? UUID().uuidString)" }.joined(separator: ";")
        if let c = combined.withLock({ $0 }), c.key == stamps { return c.index }
        let index = SanctionsListIndex(lists.flatMap(\.entries))
        combined.withLock { $0 = (stamps, index) }
        return index
    }

    /// The lists in `folder` (the files the online check keeps), read and parsed only when changed. Returns the
    /// sources found and the index over them.
    public static func local(folder: URL?, sources: [PublicSource]) -> (searched: [PublicSource], index: SanctionsListIndex) {
        var lists: [(source: PublicSource, stamp: String?, entries: [SanctionsLists.Entry])] = []
        for source in sources {
            guard let file = folder?.appendingPathComponent("\(source.rawValue).data") else { continue }
            let stamp = Self.stamp(of: file)
            guard stamp != nil, let e = entries(source, stamp: stamp, data: {
                do { return try Data(contentsOf: file, options: .mappedIfSafe) } catch {
                    KalsmritikoshLog.routing.error("Sanctions list unreadable: \(String(describing: error), privacy: .private)")
                    return nil
                }
            }) else { continue }
            lists.append((source, stamp, e))
        }
        return (lists.map(\.source), index(lists))
    }
}

/// Streams the UN list, collecting each record's name parts and aliases.
nonisolated final class UNListReader: NSObject, XMLParserDelegate {
    var entries: [SanctionsLists.Entry] = []
    private var inRecord = false, isEntity = false
    private var parts: [String: String] = [:]
    private var aliases: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "INDIVIDUAL" || name == "ENTITY" { inRecord = true; isEntity = name == "ENTITY"; parts = [:]; aliases = [] }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inRecord else { return }
        switch name {
        case "FIRST_NAME", "SECOND_NAME", "THIRD_NAME", "FOURTH_NAME", "REFERENCE_NUMBER", "UN_LIST_TYPE":
            if !value.isEmpty { parts[name] = value }
        case "ALIAS_NAME":
            if !value.isEmpty { aliases.append(value) }
        case "INDIVIDUAL", "ENTITY":
            let full = ["FIRST_NAME", "SECOND_NAME", "THIRD_NAME", "FOURTH_NAME"].compactMap { parts[$0] }.joined(separator: " ")
            let ref = parts["REFERENCE_NUMBER"] ?? ""
            let detail = [parts["UN_LIST_TYPE"], isEntity ? "entity" : "individual"].compactMap { $0 }.joined(separator: " · ")
            if !full.isEmpty { entries.append(.init(list: .unConsolidated, reference: ref, name: full, detail: detail)) }
            for a in aliases { entries.append(.init(list: .unConsolidated, reference: ref, name: a, detail: detail + " · alias")) }
            inRecord = false
        default: break
        }
    }
}

// MARK: - A8 Company registry and court records (the searched name is sent — previewed)

public nonisolated enum RegistryLookups {
    public struct Record: Equatable, Sendable {
        public let source: PublicSource
        public let title: String
        public let detail: String
        public let link: String
    }

    static func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    public static func gleifRequest(_ name: String) -> OutboundHTTPRequest {
        PublicSource.get("https://\(PublicSource.gleif.host)/api/v1/lei-records?filter%5Bfulltext%5D=\(encoded(name))&page%5Bsize%5D=20")
    }

    public static func courtRequest(_ name: String) -> OutboundHTTPRequest {
        PublicSource.get("https://\(PublicSource.courtListener.host)/api/rest/v4/search/?q=%22\(encoded(name))%22&type=o")
    }

    public static func parseGLEIF(_ data: Data) -> [Record] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let a = item["attributes"] as? [String: Any], let lei = a["lei"] as? String,
                  let entity = a["entity"] as? [String: Any],
                  let name = (entity["legalName"] as? [String: Any])?["name"] as? String else { return nil }
            let address = entity["legalAddress"] as? [String: Any]
            let place = [address?["city"] as? String, address?["country"] as? String].compactMap { $0 }.joined(separator: ", ")
            let status = [entity["status"] as? String, (a["registration"] as? [String: Any])?["status"] as? String].compactMap { $0 }.joined(separator: " / ")
            return Record(source: .gleif, title: name, detail: ["LEI \(lei)", place, status, entity["jurisdiction"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                          link: "https://search.gleif.org/#/record/\(lei)")
        }
    }

    public static func parseCourts(_ data: Data) -> [Record] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["results"] as? [[String: Any]] else { return [] }
        return items.compactMap { r in
            guard let title = r["caseName"] as? String, !title.isEmpty else { return nil }
            let detail = [r["court"] as? String, r["dateFiled"] as? String, (r["docketNumber"] as? String).map { "docket \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            let path = r["absolute_url"] as? String ?? ""
            return Record(source: .courtListener, title: title, detail: detail, link: path.isEmpty ? "" : "https://www.courtlistener.com\(path)")
        }
    }
}

// MARK: - CSV fields (quoted, RFC 4180)

nonisolated enum CSV {
    static func fields(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        var it = line.makeIterator()
        while let c = it.next() {
            if quoted {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { cur.append("\"") } else { quoted = false; if n == "," { out.append(cur); cur = "" } else { cur.append(n) } }
                    } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { out.append(cur); cur = "" }
            else { cur.append(c) }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
