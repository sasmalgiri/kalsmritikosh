//
//  ParserCapabilityManifest.swift
//  Kalsmritikosh
//
//  PAR-001 — the parser capability manifest. Generated FROM CODE (the parser
//  registry), never hand-maintained, so the advertised format matrix cannot drift
//  from what the app can actually do. Each SourceType is classified per the locked
//  product contract's support states:
//
//    FULL           — a structural parser recovers structure + exact locators.
//    PARTIAL        — recovered, but with disclosed limits (here: OCR-dependent formats,
//                     whose fidelity depends on image quality).
//    PRESERVED-ONLY — no parser; identity/metadata retained, content not interpretable.
//    DEFERRED       — recognized but processing intentionally postponed (audio/video).
//
//  Marketing/UX must read coverage from this manifest, not from prose (GOV / §5 of the
//  locked contract). A format may only be advertised "Supported" once it is FULL *and*
//  release-verified by fixtures (PAR-010).
//

import Foundation

public enum ParserCoverage: String, Codable, Sendable {
    case full = "FULL"
    case partial = "PARTIAL"
    case preservedOnly = "PRESERVED-ONLY"
    case deferred = "DEFERRED"
}

public struct ParserCapabilityEntry: Codable, Sendable, Hashable {
    public let sourceType: String
    public let category: String
    public let coverage: ParserCoverage
    public let parserName: String?
    public let parserVersion: String?
}

public struct ParserCapabilityManifest: Sendable {

    /// Build the manifest from a registry. Types the registry parses are FULL (or
    /// PARTIAL when OCR-dependent); media types are DEFERRED; everything else the app
    /// recognizes is PRESERVED-ONLY.
    public nonisolated static func generate(registry: StructuralParserRegistry) -> [ParserCapabilityEntry] {
        // Which parser (if any) handles each type, read from code.
        var byType: [SourceType: (name: String, version: String)] = [:]
        for cap in registry.capabilities {
            for t in cap.types { byType[t] = (cap.name, cap.version) }
        }

        return SourceType.allCases
            .filter { $0 != .unknown }
            .sorted { $0.rawValue < $1.rawValue }
            .map { type in
                let category = String(describing: type.category)
                if let p = byType[type] {
                    return ParserCapabilityEntry(
                        sourceType: type.rawValue,
                        category: category,
                        coverage: Self.isOCRDependent(type) ? .partial : .full,
                        parserName: p.name,
                        parserVersion: p.version)
                }
                let coverage: ParserCoverage = Self.isMedia(type) ? .deferred : .preservedOnly
                return ParserCapabilityEntry(
                    sourceType: type.rawValue,
                    category: category,
                    coverage: coverage,
                    parserName: nil,
                    parserVersion: nil)
            }
    }

    /// OCR-dependent formats: fidelity varies with scan/image quality → PARTIAL, not FULL.
    nonisolated static func isOCRDependent(_ t: SourceType) -> Bool {
        switch t {
        case .pdf, .png, .jpg, .heic, .tiff, .webp: return true
        default: return false
        }
    }

    nonisolated static func isMedia(_ t: SourceType) -> Bool {
        switch t {
        case .mp3, .wav, .m4a, .aac, .aiff, .caf, .flac, .threegp, .mp4, .mov: return true
        default: return false
        }
    }

    /// Human-readable coverage matrix for docs/UX (SUPPORTED_SOURCES.md).
    public nonisolated static func renderMarkdown(registry: StructuralParserRegistry) -> String {
        let entries = generate(registry: registry)
        var out = "| Format | Category | Coverage | Parser | Version |\n"
        out += "|---|---|---|---|---|\n"
        for e in entries {
            out += "| \(e.sourceType) | \(e.category) | \(e.coverage.rawValue) | "
                + "\(e.parserName ?? "—") | \(e.parserVersion ?? "—") |\n"
        }
        let full = entries.filter { $0.coverage == .full }.count
        let partial = entries.filter { $0.coverage == .partial }.count
        let deferred = entries.filter { $0.coverage == .deferred }.count
        let preserved = entries.filter { $0.coverage == .preservedOnly }.count
        out += "\n_Generated from code: \(full) FULL, \(partial) PARTIAL, "
            + "\(deferred) DEFERRED, \(preserved) PRESERVED-ONLY._\n"
        return out
    }
}
