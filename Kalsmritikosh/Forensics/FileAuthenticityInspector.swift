//
//  FileAuthenticityInspector.swift
//  Kalsmritikosh
//
//  On-device authenticity signals for a single file. This is deliberately
//  NOT sold as "deepfake detection" — pixel-level forensics can't be done
//  honestly on-device without huge models, and a green light would be a lie.
//  Instead it surfaces the real, deterministic provenance signals a
//  journalist / investigator / SIU examiner actually checks by hand:
//
//   • a stable SHA-256 fingerprint (so a copy can be proven identical/altered)
//   • EXIF/metadata completeness and editing-software fingerprints on images
//   • capture-date vs file-date consistency
//   • PDF producer/creator tags and — importantly — incremental-update markers
//     (a PDF saved once has a single %%EOF; extra ones mean it was appended to
//     or edited after its original save, which matters for a "final" exhibit)
//   • embedded JavaScript / auto-action markers in a PDF
//
//  Every signal is explained in plain language with a severity, and the tool
//  says plainly what it can and cannot conclude.
//

import Foundation
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct AuthenticitySignal: Sendable, Identifiable, Hashable {
    public enum Severity: String, Sendable { case info, notice, warning }
    public let id = UUID()
    public let title: String
    public let detail: String
    public let severity: Severity
}

public struct AuthenticityReport: Sendable {
    public let fileName: String
    public let sha256: String
    public let sizeBytes: Int64
    public let kindDescription: String
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let signals: [AuthenticitySignal]
}

public enum FileAuthenticityError: Error, LocalizedError, Sendable {
    case cannotRead(URL)
    public var errorDescription: String? {
        switch self {
        case .cannotRead(let u): return "Could not read \(u.lastPathComponent)."
        }
    }
}

public struct FileAuthenticityInspector: Sendable {

    public init() {}

    public func analyze(url: URL) throws -> AuthenticityReport {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: url.path) else { throw FileAuthenticityError.cannotRead(url) }

        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let created = attrs[.creationDate] as? Date
        let modified = attrs[.modificationDate] as? Date

        let hash = try sha256(of: url)
        let uti = UTType(filenameExtension: url.pathExtension.lowercased())
        var signals: [AuthenticitySignal] = []

        // Date consistency applies to every file kind.
        if let c = created, let m = modified, m < c.addingTimeInterval(-2) {
            signals.append(.init(
                title: "Modified before it was created",
                detail: "The file's modification date is earlier than its creation date. That usually means it was copied or its clock/metadata was changed after the fact.",
                severity: .warning))
        }

        if let type = uti, type.conforms(to: .image) {
            signals.append(contentsOf: imageSignals(url: url, capture: created))
        } else if let type = uti, type.conforms(to: .pdf) {
            signals.append(contentsOf: pdfSignals(url: url))
        } else {
            signals.append(.init(
                title: "No content-specific checks for this type",
                detail: "Authenticity signals are available for images (EXIF/metadata) and PDFs (producer + edit markers). The fingerprint and date checks above still apply.",
                severity: .info))
        }

        return AuthenticityReport(
            fileName: url.lastPathComponent,
            sha256: hash,
            sizeBytes: size,
            kindDescription: uti?.localizedDescription ?? url.pathExtension.uppercased(),
            createdAt: created,
            modifiedAt: modified,
            signals: signals)
    }

    // MARK: - Image signals

    private func imageSignals(url: URL, capture: Date?) -> [AuthenticitySignal] {
        var out: [AuthenticitySignal] = []
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            out.append(.init(title: "No readable image metadata",
                             detail: "The image carries no embedded properties. That is common for screenshots, re-exported, or metadata-stripped images — not proof of tampering, but it means there is no capture provenance.",
                             severity: .notice))
            return out
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        // Editing-software fingerprint.
        let software = (tiff?[kCGImagePropertyTIFFSoftware] as? String)
            ?? (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFSoftware] as? String
        if let sw = software, !sw.isEmpty {
            let editors = ["photoshop", "gimp", "lightroom", "affinity", "pixelmator", "snapseed", "facetune"]
            let isEditor = editors.contains { sw.lowercased().contains($0) }
            out.append(.init(
                title: isEditor ? "Edited in image software" : "Software tag present",
                detail: "The image records the software \"\(sw)\".\(isEditor ? " That is an image editor — the picture was processed after capture." : "")",
                severity: isEditor ? .warning : .info))
        }

        // EXIF capture provenance.
        if exif == nil {
            out.append(.init(title: "No EXIF capture data",
                             detail: "There is no camera EXIF block. Genuine camera/phone photos normally carry one; its absence is typical of screenshots, re-encodes, or stripped images.",
                             severity: .notice))
        } else {
            if let original = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
                out.append(.init(title: "Capture time recorded",
                                 detail: "EXIF DateTimeOriginal = \(original).",
                                 severity: .info))
            }
            if gps != nil {
                out.append(.init(title: "GPS location present",
                                 detail: "The image embeds GPS coordinates — useful corroboration, but also a privacy consideration before sharing.",
                                 severity: .info))
            }
        }
        return out
    }

    // MARK: - PDF signals

    private func pdfSignals(url: URL) -> [AuthenticitySignal] {
        var out: [AuthenticitySignal] = []
        if let doc = PDFDocument(url: url), let attrs = doc.documentAttributes {
            if let producer = attrs[PDFDocumentAttribute.producerAttribute] as? String {
                out.append(.init(title: "Producer", detail: producer, severity: .info))
            }
            if let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String {
                out.append(.init(title: "Creator", detail: creator, severity: .info))
            }
        }

        // Raw-byte structural signals.
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let eofCount = countOccurrences(of: "%%EOF", in: data)
            if eofCount > 1 {
                out.append(.init(
                    title: "Edited after original save (\(eofCount) revisions)",
                    detail: "A PDF written once ends with a single %%EOF marker. This file has \(eofCount), meaning content was appended or changed in \(eofCount - 1) incremental update(s) after the original save. For a document presented as final/original, that is worth explaining.",
                    severity: .warning))
            } else {
                out.append(.init(title: "Single save (no incremental edits)",
                                 detail: "The PDF has one %%EOF marker — no appended revisions after its original save.",
                                 severity: .info))
            }
            if containsToken("/JavaScript", in: data) || containsToken("/JS", in: data) {
                out.append(.init(title: "Embedded JavaScript",
                                 detail: "The PDF contains JavaScript. Legitimate for some forms, but a common vector for hidden behaviour — review before trusting.",
                                 severity: .warning))
            }
            if containsToken("/AA", in: data) {
                out.append(.init(title: "Auto-action triggers",
                                 detail: "The PDF defines automatic actions (/AA). Uncommon in ordinary documents.",
                                 severity: .notice))
            }
        }
        return out
    }

    // MARK: - Helpers

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func countOccurrences(of token: String, in data: Data) -> Int {
        guard let needle = token.data(using: .ascii), !needle.isEmpty else { return 0 }
        var count = 0
        var range = data.startIndex..<data.endIndex
        while let found = data.range(of: needle, options: [], in: range) {
            count += 1
            range = found.upperBound..<data.endIndex
        }
        return count
    }

    private func containsToken(_ token: String, in data: Data) -> Bool {
        guard let needle = token.data(using: .ascii) else { return false }
        return data.range(of: needle) != nil
    }
}
