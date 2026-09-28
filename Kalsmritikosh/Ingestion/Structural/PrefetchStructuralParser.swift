//
//  PrefetchStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-6d — turns Windows Prefetch into dated evidence of EXECUTION.
//
//  This is the one artifact in the lane that can honestly use that word.
//  Amcache proves a file was PRESENT (a scheduled scan saw it on disk); a
//  shortcut proves a file was POINTED AT; a `.pf` file exists because Windows
//  watched the executable run, counted the runs, and stamped when they
//  happened. On Windows 8 and later it keeps the last EIGHT run times, so a
//  single file yields a short execution history rather than one point.
//
//  What it does NOT establish, stated because the distinction decides cases:
//  Prefetch names the executable and a HASH of the path it ran from, not the
//  full path. Two entries with the same name and different hashes are the same
//  program run from two different locations — which is often the finding — but
//  the reader cannot say WHERE from, and does not guess.
//
//  A Windows 10+ file is LZXPRESS-Huffman compressed. It is reported as
//  present-and-not-decompressed with its declared uncompressed size, never
//  half-read: the compression could not be verified here without a real sample
//  to check a decompressor against.
//
//  Read-only, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct PrefetchStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.prefetch] }
    public nonisolated var parserName: String { "windows-prefetch" }
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
                filename: filename, detectedType: .prefetch,
                mimeType: "application/octet-stream", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "prefetch.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        let reader: PrefetchReader
        do {
            reader = try PrefetchReader(data: data)
        } catch PrefetchReader.ReaderError.compressed(let uncompressedSize) {
            // The file IS evidence — its existence means the program ran, and
            // its name carries the executable — so this is reported rather than
            // failed, with the limitation stated as its own block.
            add(.documentHeader,
                "Windows Prefetch \"\(shortName)\": present but COMPRESSED. Windows 10 and later "
                + "store prefetch bodies with LZXPRESS Huffman compression; this file declares "
                + "\(uncompressedSize) bytes uncompressed.",
                path: [], attributes: [
                    "compressed": AnyCodable(.bool(true)),
                    "declaredUncompressedBytes": AnyCodable(.int(Int64(uncompressedSize)))
                ])
            add(.paragraph,
                "The run times and run count inside this file are NOT recovered: decompressing it "
                + "requires an LZXPRESS Huffman decoder, which is not implemented here because it "
                + "could not be verified without a real compressed sample to check against — a "
                + "fixture built from the same reading of the spec as the decoder would let a "
                + "shared misunderstanding pass its own test. What this file still establishes is "
                + "that Windows created a prefetch entry, which it does when a program RUNS. The "
                + "executable name is usually recoverable from the FILENAME itself "
                + "(NAME-HASH.pf).",
                path: ["limitations"], attributes: [
                    "limitation": AnyCodable(.string("lzxpress-huffman-not-decompressed"))
                ])
            warnings.append(ParserWarning(severity: .warning, code: "prefetch.compressed",
                message: "Windows 10+ compressed prefetch (\(uncompressedSize) bytes declared "
                       + "uncompressed): the executable name is in the filename, but run times "
                       + "and run count are not decoded."))
            return document(.partial)
        } catch PrefetchReader.ReaderError.unsupportedVersion(let raw) {
            warnings.append(ParserWarning(severity: .warning, code: "prefetch.unsupported_version",
                message: "Prefetch format version \(raw) is not decoded. Versions 17 (XP/2003), "
                       + "23 (Vista/7) and 26 (Windows 8.x) are read; version 30 (Windows 10/11) "
                       + "normally arrives compressed and is reported as such."))
            return document(.partial)
        } catch PrefetchReader.ReaderError.notPrefetch {
            warnings.append(ParserWarning(severity: .error, code: "prefetch.not_prefetch",
                message: "No \"SCCA\" signature: this is not a Windows prefetch file."))
            return document(.corrupt)
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "prefetch.truncated",
                message: "The file is shorter than a prefetch header. \(error)"))
            return document(.corrupt)
        }

        var header = "Windows Prefetch \"\(shortName)\": \(reader.executableName) was RUN"
        if reader.runCount > 0 {
            header += " \(reader.runCount) time(s)"
        }
        if let latest = reader.runTimes.first {
            header += ", most recently \(Self.iso8601.string(from: latest))"
        }
        header += " (\(reader.version.label) format)."
        add(.documentHeader, header, path: [], attributes: [
            "executableName": AnyCodable(.string(reader.executableName)),
            "runCount": AnyCodable(.int(Int64(reader.runCount))),
            "prefetchVersion": AnyCodable(.int(Int64(reader.version.rawValue))),
            "evidenceOf": AnyCodable(.string("program-execution"))
        ])

        // The path-hash caveat, in the evidence rather than a comment: it is
        // what stops "same name" being read as "same program".
        add(.paragraph,
            "A prefetch file records the executable NAME and a hash of the full path it ran "
            + String(format: "from (0x%08X), not the path itself. ", reader.pathHash)
            + "Two prefetch entries with the same name but different hashes are the same program "
            + "run from DIFFERENT locations — frequently the finding — but this artifact cannot "
            + "say which locations, and none is guessed at here. Unlike an inventory entry, "
            + "however, a prefetch file exists because Windows observed the program EXECUTE.",
            path: ["pathHash"], attributes: [
                "pathHash": AnyCodable(.string(String(format: "%08X", reader.pathHash)))
            ])

        for (index, runTime) in reader.runTimes.enumerated() {
            let ordinal = index == 0 ? "Most recent run" : "Earlier run \(index + 1)"
            add(.logRecord,
                "\(ordinal) of \(reader.executableName): \(Self.iso8601.string(from: runTime)).",
                path: ["runs", String(index + 1)], attributes: [
                    "executableName": AnyCodable(.string(reader.executableName)),
                    "timestamp": AnyCodable(.string(Self.iso8601.string(from: runTime))),
                    "runOrdinal": AnyCodable(.int(Int64(index + 1))),
                    "evidenceOf": AnyCodable(.string("program-execution"))
                ])
        }
        if reader.runTimes.count > 1 {
            add(.paragraph,
                "This \(reader.version.label) file keeps up to eight run times, so the "
                + "\(reader.runTimes.count) above are an execution HISTORY rather than a single "
                + "point. Slots the format had not used yet are omitted; they are not runs dated "
                + "to 1601.",
                path: ["runs"])
        }

        for problem in reader.problems {
            warnings.append(ParserWarning(severity: .warning, code: "prefetch.partial",
                                          message: problem))
        }
        // Complete: for these versions every field the format defines is read.
        return document(.complete)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
