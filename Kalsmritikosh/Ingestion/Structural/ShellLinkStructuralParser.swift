//
//  ShellLinkStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-6a — turns a Windows shortcut into evidence about a file that may no
//  longer exist.
//
//  What a `.lnk` in `Recent` establishes: a file with THIS path, THIS size, on a
//  volume with THIS serial number and THIS drive type, was pointed at from this
//  machine. When the drive type is REMOVABLE, that is a file on a USB stick —
//  often the only surviving record that the file was ever there.
//
//  THE MISREADING THIS PARSER IS BUILT TO PREVENT: the three FILETIMEs in a
//  shortcut are the TARGET FILE's created / accessed / written times as they
//  stood when the shortcut was last updated. They are NOT when the shortcut was
//  used, and they are not evidence of an access at that moment. Every one of
//  them is labelled as the target's own time, in the text of the evidence, so an
//  answer cannot quote "accessed 09:26" as though this file recorded the access.
//  When the shortcut's own filesystem times matter, they come from the ledger's
//  file metadata — a different fact, from a different place.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct ShellLinkStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.shellLink] }
    public nonisolated var parserName: String { "windows-shell-link" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

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
                filename: filename, detectedType: .shellLink,
                mimeType: "application/x-ms-shortcut", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "lnk.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        let link: ShellLinkReader
        do {
            link = try ShellLinkReader(data: data)
        } catch ShellLinkReader.ReaderError.notAShellLink {
            warnings.append(ParserWarning(severity: .error, code: "lnk.not_lnk",
                message: "This is not a Windows shortcut: the 76-byte header and shell-link "
                       + "class id are absent."))
            return document(.corrupt)
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "lnk.truncated",
                message: "The shortcut is shorter than its own header. \(error)"))
            return document(.corrupt)
        }

        // MARK: What the shortcut pointed AT

        var header = "Windows shortcut \"\(shortName)\""
        if let target = link.targetPath {
            header += " → \(target)"
        } else if let relative = link.relativePath {
            header += " → \(relative) (relative path only; no absolute path recorded)"
        } else {
            header += " — the target's path was not recorded in this shortcut"
        }
        if link.targetIsDirectory { header += " [a folder]" }
        header += "."
        var headerAttributes: [String: AnyCodable] = [:]
        if let target = link.targetPath {
            headerAttributes["targetPath"] = AnyCodable(.string(target))
        }
        headerAttributes["targetIsDirectory"] = AnyCodable(.bool(link.targetIsDirectory))
        add(.documentHeader, header, path: [], attributes: headerAttributes)

        if let target = link.targetPath ?? link.relativePath {
            var line = "The shortcut points at \(target)"
            if link.targetSizeBytes > 0 {
                line += ", recorded as \(Self.byteCount(link.targetSizeBytes))"
            }
            line += ". A shortcut survives its target: the file may since have been deleted, "
                + "renamed, or carried away on the device it lived on."
            add(.paragraph, line, path: ["target"], attributes: [
                "targetPath": AnyCodable(.string(target)),
                "targetSizeBytes": AnyCodable(.int(Int64(link.targetSizeBytes)))
            ])
        }

        // MARK: The volume — the part that identifies a device

        if let volume = link.volume {
            var line = "The target was on a \(volume.driveType.label) volume"
            if let label = volume.label { line += " labelled \"\(label)\"" }
            if volume.serialNumber != 0 {
                line += String(format: ", volume serial number %08X", volume.serialNumber)
            }
            line += "."
            if volume.driveType == .removable {
                line += " A removable volume means the file was NOT on this machine's own disk: "
                    + "it was on a device that could be taken away, and the serial number is what "
                    + "identifies that device across machines."
            }
            var attributes: [String: AnyCodable] = [
                "driveType": AnyCodable(.string(String(describing: volume.driveType)))
            ]
            if volume.serialNumber != 0 {
                attributes["volumeSerialNumber"] =
                    AnyCodable(.string(String(format: "%08X", volume.serialNumber)))
            }
            if let label = volume.label { attributes["volumeLabel"] = AnyCodable(.string(label)) }
            add(.paragraph, line, path: ["volume"], attributes: attributes)
        }
        if let network = link.networkPath {
            add(.paragraph,
                "The target was on a network share: \(network). The share name is evidence of a "
                + "server the account had access to, whether or not the file is still there.",
                path: ["volume"], attributes: ["networkPath": AnyCodable(.string(network))])
        }

        // MARK: Times — each one labelled as the TARGET's

        let times: [(String, Date?, String)] = [
            ("created", link.targetCreated, "targetCreated"),
            ("last accessed", link.targetAccessed, "targetAccessed"),
            ("last written", link.targetWritten, "targetWritten")
        ]
        let recorded = times.filter { $0.1 != nil }
        if recorded.isEmpty {
            add(.paragraph,
                "This shortcut records no timestamps for its target.",
                path: ["times"])
        } else {
            for (label, date, key) in recorded {
                guard let date else { continue }
                add(.logRecord,
                    // The wording is deliberate and load-bearing: "the TARGET FILE
                    // was \(label)", never "the shortcut was used at".
                    "The TARGET FILE was \(label) \(Self.iso8601.string(from: date)) — this is the "
                    + "target's own timestamp as it stood when the shortcut was last updated, NOT "
                    + "the time the shortcut was used.",
                    path: ["times", key], attributes: [
                        "timestamp": AnyCodable(.string(Self.iso8601.string(from: date))),
                        "describes": AnyCodable(.string("target-file")),
                        "timeKind": AnyCodable(.string(key))
                    ])
            }
        }

        // MARK: Everything else the link states

        if let arguments = link.commandLineArguments {
            // Arguments on a shortcut are how a program was actually invoked —
            // a script path, a flag, a remote address.
            add(.logRecord,
                "The shortcut runs the target with arguments: \(arguments)",
                path: ["arguments"],
                attributes: ["arguments": AnyCodable(.string(arguments))])
        }
        if let workingDirectory = link.workingDirectory {
            add(.paragraph, "Working directory: \(workingDirectory)", path: ["workingDirectory"],
                attributes: ["workingDirectory": AnyCodable(.string(workingDirectory))])
        }
        if let name = link.name {
            add(.paragraph, "Shortcut description: \(name)", path: ["description"],
                attributes: ["description": AnyCodable(.string(name))])
        }
        if let icon = link.iconLocation {
            add(.paragraph, "Icon location: \(icon)", path: ["icon"],
                attributes: ["iconLocation": AnyCodable(.string(icon))])
        }

        if let tracker = link.tracker {
            var line = "The shortcut was created on a machine whose NetBIOS name is "
                + "\"\(tracker.machineID)\""
            var attributes: [String: AnyCodable] = [
                "machineID": AnyCodable(.string(tracker.machineID))
            ]
            if let mac = tracker.macAddress {
                line += ", whose network adapter address was \(mac)"
                attributes["macAddress"] = AnyCodable(.string(mac))
            }
            line += ". This names the machine that MADE the shortcut, which is not necessarily "
                + "the machine it was found on."
            add(.logRecord, line, path: ["tracker"], attributes: attributes)
        }

        if let idListSize = link.targetIDListSize {
            // Declared, not decoded — and saying so is better than leaving a
            // reader to assume the shortcut carried nothing more.
            warnings.append(ParserWarning(severity: .warning, code: "lnk.idlist_not_decoded",
                message: "The shortcut carries a \(idListSize)-byte shell-item id list, which is "
                       + "not decoded: it is a loosely-documented per-folder tagged format. The "
                       + "path information worth having is read from the location block and the "
                       + "relative path instead. Nothing in the id list is reported as a fact."))
        }
        for problem in link.problems {
            warnings.append(ParserWarning(severity: .warning, code: "lnk.partial", message: problem))
        }

        // A shortcut that yielded neither a path nor a time is not a useful
        // reading of the file, even though the header parsed.
        let hasSubstance = link.targetPath != nil || link.relativePath != nil
            || !recorded.isEmpty || link.tracker != nil
        return document(hasSubstance ? .complete : .partial)
    }

    private nonisolated static func byteCount(_ bytes: UInt32) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
