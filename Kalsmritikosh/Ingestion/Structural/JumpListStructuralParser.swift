//
//  JumpListStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-6b — Windows jump lists: which files an application was used to open.
//
//  This unit composes two readers that are already verified rather than adding
//  a third format. A `.automaticDestinations-ms` jump list is an MS-CFB (OLE2)
//  container — the same container `.doc` and `.msg` use — and each of its
//  streams is a complete SHELL LINK, the structure HOST-6a reads. A
//  `.customDestinations-ms` file is a plain sequence of shell links, found by
//  their 20-byte signature.
//
//  So every target a jump list names comes back with everything HOST-6a
//  recovers: full original path, size, volume serial number, drive type
//  (including REMOVABLE), and the target's own timestamps. What the jump list
//  ADDS is the association: these files are recorded under one application.
//
//  WHAT IS NOT CLAIMED, in two places:
//
//  1. The APPLICATION is identified by the AppID in the filename — a 16-hex-digit
//     value. Mapping an AppID to a product name requires a community-maintained
//     lookup table, so the AppID is reported VERBATIM and no application is
//     named. A wrong application name here would attribute a file to software
//     the person may never have run.
//  2. The `DestList` stream holds the most-recently-used order and per-entry
//     access counts and times, at offsets that are community-derived rather than
//     documented. It is reported as present and NOT interpreted, for the same
//     reason the legacy Amcache schema and EVTX BinXML templates are not.
//
//  The target-timestamp disclaimer from HOST-6a rides along unchanged: those
//  times belong to the TARGET FILE, not to the moment the jump-list entry was
//  made.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct JumpListStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.jumpList] }
    public nonisolated var parserName: String { "windows-jump-list" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    /// The stream that carries the MRU order and access counts. Present in every
    /// automatic jump list; deliberately not decoded.
    nonisolated static let destListStreamName = "destlist"

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let shortName = (filename as NSString).lastPathComponent
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String],
                 attributes: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: [shortName] + path),
                attributes: attributes))
        }
        func document(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .jumpList,
                mimeType: "application/octet-stream", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "jumplist.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        let appID = Self.appID(fromFilename: shortName)
        var links: [(stream: String, link: ShellLinkReader)] = []
        var destListBytes: Int?
        var unreadableStreams: [String] = []
        let isAutomatic: Bool

        if let ole = try? OLE2Reader(data: data) {
            isAutomatic = true
            for entry in ole.rootChildren() {
                let bytes = ole.readEntryData(entry)
                if entry.name.lowercased() == Self.destListStreamName {
                    destListBytes = bytes.count
                    continue
                }
                guard !bytes.isEmpty else { continue }
                if let link = try? ShellLinkReader(data: bytes) {
                    links.append((entry.name, link))
                } else {
                    unreadableStreams.append(entry.name)
                }
            }
        } else {
            // A custom-destinations list is not a container at all: it is shell
            // links back to back, located by their signature.
            isAutomatic = false
            for (index, bytes) in Self.embeddedShellLinks(in: data).enumerated() {
                if let link = try? ShellLinkReader(data: bytes) {
                    links.append((String(index + 1), link))
                }
            }
        }

        guard !links.isEmpty else {
            if destListBytes != nil {
                warnings.append(ParserWarning(severity: .warning, code: "jumplist.no_links",
                    message: "This jump list holds its most-recently-used stream but no readable "
                           + "shell-link streams, so no target file could be recovered."))
                return document(.empty)
            }
            warnings.append(ParserWarning(severity: .error, code: "jumplist.not_a_jumplist",
                message: "No shell links found: this is neither an MS-CFB jump list nor a "
                       + "sequence of shell links."))
            return document(.corrupt)
        }

        var header = "Windows jump list \"\(shortName)\": \(links.count) target(s) recorded"
        if let appID { header += " under application id \(appID)" }
        header += isAutomatic ? " (automatic destinations)." : " (custom destinations)."
        var headerAttributes: [String: AnyCodable] = [
            "targetCount": AnyCodable(.int(Int64(links.count))),
            "jumpListKind": AnyCodable(.string(isAutomatic ? "automatic" : "custom"))
        ]
        if let appID { headerAttributes["applicationID"] = AnyCodable(.string(appID)) }
        add(.documentHeader, header, path: [], attributes: headerAttributes)

        add(.paragraph,
            "A jump list records files opened with ONE application, which is what it adds over a "
            + "loose shortcut. The application is identified only by the AppID in the filename"
            + (appID.map { " (\($0))" } ?? "")
            + "; translating an AppID into a product name needs a community-maintained lookup "
            + "table, so NO application is named here — a wrong name would attribute these files "
            + "to software that may never have been run. Each target's timestamps below belong "
            + "to the TARGET FILE, not to the moment it was opened.",
            path: ["limitations"], attributes: [
                "limitation": AnyCodable(.string("appid-not-resolved-to-application"))
            ])

        for (stream, link) in links {
            let target = link.targetPath ?? link.relativePath
            var line = "Recorded target: \(target ?? "(no path recorded in this entry)")"
            if link.targetSizeBytes > 0 { line += ", \(link.targetSizeBytes) bytes" }
            if let volume = link.volume {
                line += ", on a \(volume.driveType.label) volume"
                if let label = volume.label { line += " labelled \"\(label)\"" }
                if volume.serialNumber != 0 {
                    line += String(format: ", volume serial %08X", volume.serialNumber)
                }
            }
            if let network = link.networkPath { line += ", on network share \(network)" }
            line += "."
            var attributes: [String: AnyCodable] = [
                "stream": AnyCodable(.string(stream)),
                "evidenceOf": AnyCodable(.string("file-opened-with-application"))
            ]
            if let target { attributes["targetPath"] = AnyCodable(.string(target)) }
            if let appID { attributes["applicationID"] = AnyCodable(.string(appID)) }
            if let volume = link.volume {
                attributes["driveType"] = AnyCodable(.string(String(describing: volume.driveType)))
            }
            add(.logRecord, line, path: ["targets", stream], attributes: attributes)

            // The target's own times, each carrying the same disclaimer HOST-6a
            // established — a retrieved answer quotes a block, so it has to
            // travel with the fact.
            let times: [(String, Date?)] = [
                ("created", link.targetCreated),
                ("last accessed", link.targetAccessed),
                ("last written", link.targetWritten)
            ]
            for (label, date) in times {
                guard let date else { continue }
                add(.logRecord,
                    "The TARGET FILE \(target.map { "\($0) " } ?? "")was \(label) "
                    + "\(Self.iso8601.string(from: date)) — this is the target's own timestamp as "
                    + "recorded in the jump-list entry, NOT the time the file was opened.",
                    path: ["targets", stream, "times"], attributes: [
                        "timestamp": AnyCodable(.string(Self.iso8601.string(from: date))),
                        "describes": AnyCodable(.string("target-file"))
                    ])
            }
            if let tracker = link.tracker {
                var trackerLine = "This entry was created on a machine whose NetBIOS name is "
                    + "\"\(tracker.machineID)\""
                var trackerAttributes: [String: AnyCodable] = [
                    "machineID": AnyCodable(.string(tracker.machineID))
                ]
                if let mac = tracker.macAddress {
                    trackerLine += ", whose network adapter address was \(mac)"
                    trackerAttributes["macAddress"] = AnyCodable(.string(mac))
                }
                trackerLine += "."
                add(.logRecord, trackerLine, path: ["targets", stream, "tracker"],
                    attributes: trackerAttributes)
            }
        }

        if let destListBytes {
            warnings.append(ParserWarning(severity: .warning, code: "jumplist.destlist_not_decoded",
                message: "The \(destListBytes)-byte DestList stream — which holds the "
                       + "most-recently-used ORDER and each entry's access COUNT and last access "
                       + "time — is not decoded: its layout is community-derived rather than "
                       + "documented and is version-dependent, so a mis-read offset would report "
                       + "a wrong access count or time as though it were read. The targets "
                       + "themselves come from the shell-link streams, which are documented."))
        }
        if !unreadableStreams.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "jumplist.partial",
                message: "\(unreadableStreams.count) stream(s) in this jump list did not parse as "
                       + "shell links and were not reported: \(unreadableStreams.prefix(5).joined(separator: ", "))."))
        }
        return document(.complete)
    }

    /// The AppID is the filename stem — a 16-hex-digit application identifier.
    /// Returned verbatim, never translated.
    nonisolated static func appID(fromFilename filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        let candidate = stem.lowercased()
        guard candidate.count >= 8, candidate.count <= 20,
              candidate.allSatisfy(\.isHexDigit) else { return nil }
        return candidate
    }

    /// Shell links laid end to end, located by the 20-byte header-size +
    /// class-id signature. Each link's extent is found by the NEXT signature (or
    /// the end of the file), which is what makes this a scan rather than a guess:
    /// the signature is specific enough that a false positive would have to
    /// reproduce all twenty bytes.
    nonisolated static func embeddedShellLinks(in data: Data) -> [Data] {
        let signature = ShellLinkReader.signature
        var starts: [Int] = []
        var index = 0
        let limit = data.count - signature.count
        while index <= limit {
            let slice = data.subdata(in: index..<(index + signature.count))
            if Array(slice) == signature {
                starts.append(index)
                index += signature.count
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return [] }
        var out: [Data] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : data.count
            guard end > start else { continue }
            out.append(data.subdata(in: start..<end))
        }
        return out
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
