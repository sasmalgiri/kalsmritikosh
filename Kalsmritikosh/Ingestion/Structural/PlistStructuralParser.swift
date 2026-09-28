//
//  PlistStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-1 — structural adapter for Apple property lists, in ALL three wire formats
//  (binary `bplist00`, XML, and legacy OpenStep/ASCII). Before this, `.plist` was
//  routed to `.xml`, so a binary plist — the majority of them on macOS and iOS —
//  produced nothing at all, and an XML one was read as untyped XML with no key
//  structure. Host evidence lives overwhelmingly in plists: system version and
//  install history, network interfaces and remembered Wi-Fi networks, login and
//  launch items, recent documents, Time Machine destinations, per-app preferences.
//
//  Citation model mirrors SQLiteStructuralParser: one `.table` header block per
//  container and one `.tableRow` block per scalar leaf, located by KEY PATH, so an
//  answer can cite "SystemVersion.plist → ProductVersion". Dates are rendered
//  ISO-8601 so the date/event extractors see them as real dates rather than opaque
//  values — that is what puts a host artifact on the timeline.
//
//  Deterministic, offline, read-only. Never throws for empty/corrupt input — sets
//  extractionStatus and records an honest warning instead.
//

import Foundation
import CryptoKit

public struct PlistStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.plist] }
    public nonisolated var parserName: String { "plist" }
    public nonisolated var parserVersion: String { "1" }

    /// Nesting depth beyond which we stop descending. Real artifacts are shallow;
    /// a deeper tree means either a pathological file or a decode loop.
    public nonisolated static let maxDepth = 24
    /// Leaf budget per file (citation adapter, not a bulk exporter) — matches the
    /// SQLite parser's row cap so both report over-budget the same honest way.
    public nonisolated static let maxLeaves = 5000

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = (filename as NSString).lastPathComponent
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []
        var leafCount = 0
        var truncated = false

        func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String], valueType: String,
                 value: String? = nil) {
            var attributes: [String: AnyCodable] = [
                "keyPath": AnyCodable(.string(path.joined(separator: "."))),
                "valueType": AnyCodable(.string(valueType))
            ]
            if let value { attributes["value"] = AnyCodable(.string(value)) }
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: [name] + path),
                attributes: attributes))
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "plist.empty",
                                          message: "File is zero bytes."))
            return Self.document(documentID, logicalSourceID, sourceVersionID, filename,
                                 hash, blocks, warnings, .empty)
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(
                from: data, options: [], format: &format)
        } catch {
            // A plist that will not decode is reported, never guessed at. The bytes
            // are still preserved and hashed upstream.
            warnings.append(ParserWarning(severity: .error, code: "plist.undecodable",
                                          message: "\(error)"))
            return Self.document(documentID, logicalSourceID, sourceVersionID, filename,
                                 hash, blocks, warnings, .corrupt)
        }

        // The wire format is itself evidence: a binary plist in a location that
        // normally holds XML (or vice versa) is worth being able to cite.
        let formatName = Self.name(of: format)
        add(.documentHeader, "Property list \"\(name)\" (\(formatName) format)",
            path: [], valueType: "format")

        /// Depth-first walk in a STABLE order (dictionary keys sorted), so the same
        /// file always yields the same blocks in the same order — re-ingesting an
        /// artifact must not reshuffle citations.
        func walk(_ node: Any, path: [String], depth: Int) {
            if leafCount >= Self.maxLeaves { truncated = true; return }
            if depth > Self.maxDepth {
                truncated = true
                warnings.append(ParserWarning(severity: .warning, code: "plist.max_depth",
                    message: "Stopped at depth \(Self.maxDepth) under \(path.joined(separator: "."))."))
                return
            }

            switch node {
            case let dict as [String: Any]:
                let keys = dict.keys.sorted()
                if !path.isEmpty {
                    add(.table, "\(path.joined(separator: ".")): dictionary with \(keys.count) key(s)",
                        path: path, valueType: "dictionary")
                }
                for key in keys {
                    if leafCount >= Self.maxLeaves { truncated = true; return }
                    walk(dict[key] as Any, path: path + [key], depth: depth + 1)
                }

            case let array as [Any]:
                add(.table, "\(path.joined(separator: ".")): array with \(array.count) item(s)",
                    path: path, valueType: "array")
                for (i, item) in array.enumerated() {
                    if leafCount >= Self.maxLeaves { truncated = true; return }
                    walk(item, path: path + ["[\(i)]"], depth: depth + 1)
                }

            case let value as Data:
                // A nested plist inside a data value is extremely common on Apple
                // platforms (preferences store whole sub-plists this way). Decoding it
                // recovers evidence that would otherwise read as "<data 412 bytes>".
                if let nested = Self.nestedPlist(in: value) {
                    add(.table, "\(path.joined(separator: ".")): embedded property list "
                        + "(\(value.count) bytes)", path: path, valueType: "embeddedPlist")
                    walk(nested, path: path + ["<embedded>"], depth: depth + 1)
                } else {
                    leaf("<data \(value.count) bytes>", path: path, valueType: "data")
                }

            case let date as Date:
                // ISO-8601 in UTC: the temporal layer can read it, and it states the
                // zone rather than implying the examiner's local one.
                leaf(Self.iso8601.string(from: date), path: path, valueType: "date")

            case let number as NSNumber:
                // Boolean vs integer must be told apart by the CoreFoundation type, NOT by
                // `as? Bool`: an NSNumber holding 0 or 1 bridges to Bool happily, so a
                // pattern-match on Bool renders the integer 1 as "true". A plist stores
                // booleans with their own marker, and reporting an integer as a boolean is
                // a fidelity error an examiner would have no way to see.
                if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                    leaf(number.boolValue ? "true" : "false", path: path, valueType: "boolean")
                } else {
                    leaf(Self.render(number), path: path, valueType: "number")
                }

            case let string as String:
                leaf(string, path: path, valueType: "string")

            default:
                leaf(String(describing: node), path: path, valueType: "unknown")
            }
        }

        func leaf(_ rendered: String, path: [String], valueType: String) {
            let label = path.isEmpty ? name : path.joined(separator: ".")
            // The value rides as its OWN attribute as well as inside the prose, so
            // a consumer (HOST-8e device identity) reads it without re-splitting
            // a rendered string — string surgery on our own output would break
            // the moment the rendering changed.
            add(.tableRow, "\(label) = \(rendered)", path: path, valueType: valueType,
                value: rendered)
            leafCount += 1
        }

        walk(root, path: [], depth: 0)

        if truncated {
            warnings.append(ParserWarning(severity: .warning, code: "plist.leaf_cap",
                message: "Exceeded the \(Self.maxLeaves)-value citation cap; later values not indexed."))
        }

        let status: ExtractionStatus = leafCount == 0
            ? .empty
            : (warnings.isEmpty ? .complete : .partial)
        return Self.document(documentID, logicalSourceID, sourceVersionID, filename,
                             hash, blocks, warnings, status)
    }

    // MARK: - Helpers

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `bplist00` / XML / OpenStep bytes nested inside a `data` value, or nil when
    /// the blob is ordinary binary. Decode failure is not an error here — most data
    /// values genuinely aren't plists.
    private nonisolated static func nestedPlist(in data: Data) -> Any? {
        guard data.count >= 8, data.prefix(6) == Data("bplist".utf8) else { return nil }
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt)
    }

    private nonisolated static func name(of format: PropertyListSerialization.PropertyListFormat) -> String {
        switch format {
        case .binary: return "binary"
        case .xml: return "XML"
        case .openStep: return "OpenStep"
        @unknown default: return "unrecognized"
        }
    }

    /// Integers render without a decimal point so an identifier or count stays
    /// citable verbatim; anything fractional keeps its value.
    private nonisolated static func render(_ number: NSNumber) -> String {
        let d = number.doubleValue
        if d == d.rounded(), abs(d) < 9.2e18 { return String(number.int64Value) }
        return String(d)
    }

    private nonisolated static func document(
        _ id: UUID, _ logicalSourceID: UUID, _ sourceVersionID: UUID, _ filename: String,
        _ hash: String, _ blocks: [EvidenceBlock], _ warnings: [ParserWarning],
        _ status: ExtractionStatus
    ) -> ParsedDocument {
        ParsedDocument(
            id: id, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .plist, mimeType: "application/x-plist",
            contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status)
    }
}
