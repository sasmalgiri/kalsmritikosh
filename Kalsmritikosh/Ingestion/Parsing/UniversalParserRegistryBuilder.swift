//
//  UniversalParserRegistryBuilder.swift
//  Kalsmritikosh
//
//  USF-M1 (USF-003) — constructs the ONE immutable production registry. It is the single source of
//  routing truth: exactly one plugin owns each SourceType. The existing loader + structural-parser
//  instances are used here ONLY as construction inputs (their algorithms are untouched); at runtime
//  IngestCoordinator dispatches through the UniversalParserRegistry, never the old registries.
//  Feature-gated parsers remain feature-gated; media is deferred unless the .mediaTranscription
//  module is enabled, in which case the on-device ASR loaders own audio/video.
//

import Foundation
import os

public enum UniversalParserRegistryBuilder {

    /// The complete production registry with injected dependencies. Immutable once built.
    @MainActor
    public static func standard(ocr: any OCREngine, iMessageEnabled: Bool = false,
                                browserHistoryEnabled: Bool = false, chatExportEnabled: Bool = false,
                                mediaTranscriptionEnabled: Bool = false,
                                transcriber: (any AudioTranscribing)? = nil) throws -> UniversalParserRegistry {
        let structural = StructuralParserRegistry.standard(ocr: ocr)

        // Real content loaders. Audio/video join only when transcription is enabled (below).
        var loaders: [any Ingestor] = [
            TextLoader(), PDFLoader(ocr: ocr), DocxLoader(), SpreadsheetLoader(), PresentationLoader(),
            EpubLoader(), EmailLoader(), ImageLoader(ocr: ocr), ArchiveLoader(), PlistLoader(), RegistryHiveLoader(),
            SQLiteLoader(), DiscussionExportLoader(), CustodyManifestLoader(),
            EVTXLoader(), UtmpLoader(), ShellLinkLoader(), AmcacheLoader(), MFTLoader(), JumpListLoader(), PrefetchLoader()
        ]
        if iMessageEnabled { loaders.append(IMessageLoader()) }
        if browserHistoryEnabled { loaders.append(BrowserHistoryLoader()) }
        // DISC-6 — when the gate is open, the DISCUSSION loader owns chat exports:
        // it yields per-message records (sender, date, thread) where ChatExportLoader
        // produced a single normalized text blob. ChatExportLoader is left in place
        // for the legacy LoaderRegistry and is no longer reached from this path.
        if chatExportEnabled {
            loaders.append(DiscussionExportLoader(supportedTypes: [.chatExport]))
        }
        // MEDIA (module .mediaTranscription, opt-in). The ASR lane — AudioLoader /
        // VideoLoader over the on-device Apple Speech transcriber, which forces
        // requiresOnDeviceRecognition, plus the transcript repository and view —
        // has existed since the media work landed, but was deliberately NOT
        // registered here, so recordings stayed preserved-only and no
        // transcription ever ran. Enabling the module admits both loaders, and
        // the timecodes ASRSegment embeds in the transcript text ride through
        // chunking into cited answers ("in recording.m4a at 12:34").
        if mediaTranscriptionEnabled {
            let transcriber = transcriber ?? SpeechTranscriber()   // injectable for tests (F02)
            loaders.append(AudioLoader(transcriber: transcriber))
            loaders.append(VideoLoader(transcriber: transcriber))
        }
        func realLoader(_ t: SourceType) -> (any Ingestor)? { loaders.first { $0.supportedTypes.contains(t) } }

        var plugins: [any UniversalParserPlugin] = []
        for t in SourceType.allCases where t != .unknown {
            let struc = structural.parser(for: t)
            switch t.category {
            case .audio, .video:
                // Transcription ON → the real ASR loader transcribes on-device and
                // the recording becomes searchable, citable text. OFF → recognized,
                // custody kept, interpretation deferred, exactly as before.
                if let l = realLoader(t) {
                    plugins.append(ExistingParserPluginAdapter(
                        pluginID: "media.\(t.rawValue)", pluginVersion: "1", supportedTypes: [t],
                        executionMode: .immediate, loader: l, structural: nil,
                        declaredSurfaces: [.text, .metadata]))
                } else {
                    plugins.append(PreservedOnlyPlugin(pluginID: "media.\(t.rawValue)", supportedTypes: [t], executionMode: .deferred))
                }
            case .archive:
                if let l = realLoader(t) {
                    plugins.append(ExistingParserPluginAdapter(
                        pluginID: "container.\(t.rawValue)", pluginVersion: "1", supportedTypes: [t],
                        executionMode: .container, loader: l, structural: nil, declaredSurfaces: [.attachments]))
                } else {
                    plugins.append(PreservedOnlyPlugin(pluginID: "container.\(t.rawValue)", supportedTypes: [t], executionMode: .container))
                }
            default:
                if let l = realLoader(t) {
                    plugins.append(ExistingParserPluginAdapter(
                        pluginID: "format.\(t.rawValue)", pluginVersion: struc?.parserVersion ?? "1", supportedTypes: [t],
                        executionMode: .immediate, loader: l, structural: struc,
                        requiresOCR: ParserCapabilityManifest.isOCRDependent(t),
                        declaredSurfaces: Self.declaredSurfaces(for: t, hasStructural: struc != nil)))
                } else if let struc, !Self.featureGated.contains(t) {
                    // Structural-only type (html/json/xml/log): TextLoader reads the bytes; the
                    // STRUCTURE comes from the structural parser. Intentional text-fallback reader.
                    // Only for types whose bytes really ARE text — a binary format routed here
                    // dies, because TextLoader throws on binary and a loader throw fails the whole
                    // plugin. That is why plist, registryHive and sqlite each own a real loader.
                    // Feature-gated types are excluded: their loader being absent MEANS the gate
                    // is off, and reaching them through this fallback would silently open it.
                    plugins.append(ExistingParserPluginAdapter(
                        pluginID: "format.\(t.rawValue)", pluginVersion: struc.parserVersion, supportedTypes: [t],
                        executionMode: .immediate, loader: TextLoader(), structural: struc, enforceLoaderTypeSupport: false,
                        declaredSurfaces: Self.declaredSurfaces(for: t, hasStructural: true)))
                } else {
                    // Recognized but no interpretation path — preserved-only (honest).
                    plugins.append(PreservedOnlyPlugin(pluginID: "format.\(t.rawValue)", supportedTypes: [t]))
                }
            }
        }

        // Explicit unknown fallback — deterministic text decode, never a silent substitution.
        let unknownFallback = ExistingParserPluginAdapter(
            pluginID: "system.generic-text-fallback", pluginVersion: "1", supportedTypes: [.unknown],
            executionMode: .immediate, loader: TextLoader(), structural: nil, enforceLoaderTypeSupport: false,
            declaredSurfaces: [.text])

        return try UniversalParserRegistry(plugins: plugins, unknownFallback: unknownFallback)
    }

    // MARK: - P3.5 · the format-coverage claim is DERIVED from the registry
    //
    // SUPPORTED_SOURCES.md is hand-maintained: "36 FULL · 7 PARTIAL · 10 media ·
    // 9 PRESERVED-ONLY". Every number in it was true when typed and none of them
    // is checked against anything. A hand-kept capability claim drifts the moment
    // a plugin changes mode, and a coverage document that OVERSTATES what the app
    // reads is worse than no document at all — a user points it at a format the
    // table promised and gets silence, with no way to tell the difference between
    // "unsupported" and "broken".
    //
    // So derive the claim from the registry that actually runs. Same principle as
    // PIPELINE_MATRIX.md and MODULE_MATRIX.md: where a document and the code can
    // disagree, generate the document.

    /// What the app can genuinely do with one source type, read off the built registry.
    public struct TypeCoverage: Sendable, Equatable {
        public let type: SourceType
        public let pluginID: String
        public let mode: UniversalParserExecutionMode
        /// The plugin declares a structural parser — typed, located EvidenceBlocks
        /// rather than a flat text decode.
        public let producesStructure: Bool
        /// Fidelity varies with image quality; worth stating next to a coverage claim.
        public let requiresOCR: Bool
        /// True when this type is only present because a feature gate was open.
        public let featureGated: Bool

        /// The honest one-word claim, derived from mode + structural-parser
        /// presence rather than asserted per type, so it cannot be overstated.
        ///
        /// Exhaustive over `UniversalParserExecutionMode` ON PURPOSE — no
        /// `default`. Adding an execution mode must force a decision about what
        /// it means for coverage, rather than defaulting into a word that
        /// happens to be reassuring.
        public var level: String {
            switch mode {
            case .immediate:
                // A structural parser means typed evidence blocks; a loader
                // alone means searchable text only. Calling the latter FULL is
                // precisely the overstatement this exists to prevent.
                return producesStructure ? "FULL" : "TEXT-ONLY"
            case .container:     return "CONTAINER"
            case .deferred:      return "DEFERRED"
            case .preservedOnly: return "PRESERVED-ONLY"
            }
        }
    }

    /// Coverage for every type the registry claims, in a deterministic order.
    ///
    /// Takes the SAME arguments as `standard` so the report reflects the registry
    /// as CONFIGURED — a run with iMessage disabled must not advertise iMessage
    /// support. That is exactly how a feature-gated absence becomes a false promise.
    @MainActor
    public static func coverage(
        ocr: any OCREngine,
        iMessageEnabled: Bool = false,
        browserHistoryEnabled: Bool = false,
        chatExportEnabled: Bool = false,
        mediaTranscriptionEnabled: Bool = false
    ) throws -> [TypeCoverage] {
        let registry = try standard(
            ocr: ocr, iMessageEnabled: iMessageEnabled,
            browserHistoryEnabled: browserHistoryEnabled,
            chatExportEnabled: chatExportEnabled,
            mediaTranscriptionEnabled: mediaTranscriptionEnabled)
        var out: [TypeCoverage] = []
        for plugin in registry.plugins {
            for type in plugin.supportedTypes {
                out.append(TypeCoverage(
                    type: type,
                    pluginID: plugin.pluginID,
                    mode: plugin.executionMode,
                    producesStructure: plugin.capabilities.producesStructure,
                    requiresOCR: plugin.capabilities.requiresOCR,
                    featureGated: featureGated.contains(type)))
            }
        }
        // Group by claim, then by type name — stable output so a generated
        // document diffs cleanly and an unnoticed capability change shows up as
        // a line moving between groups.
        return out.sorted {
            $0.level == $1.level ? $0.type.rawValue < $1.type.rawValue : $0.level < $1.level
        }
    }

    /// Types `SourceType` declares that NO plugin claims.
    ///
    /// The most important line of the report and the one a hand-written table can
    /// never produce: a format the app can DETECT but cannot READ. Those fall
    /// through to the unknown fallback's generic text decode, which for a binary
    /// format yields nothing usable — and today the user is given no reason.
    @MainActor
    public static func unclaimedTypes(
        ocr: any OCREngine,
        iMessageEnabled: Bool = false,
        browserHistoryEnabled: Bool = false,
        chatExportEnabled: Bool = false,
        mediaTranscriptionEnabled: Bool = false
    ) throws -> [SourceType] {
        let claimed = Set(try coverage(
            ocr: ocr, iMessageEnabled: iMessageEnabled,
            browserHistoryEnabled: browserHistoryEnabled,
            chatExportEnabled: chatExportEnabled,
            mediaTranscriptionEnabled: mediaTranscriptionEnabled).map(\.type))
        return SourceType.allCases
            .filter { !claimed.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// The coverage section for the Ingestion Report (P4), as plain text.
    ///
    /// Returns nil when `.generatedSourceCoverage` is off — a report section that
    /// silently substitutes stale hand-written numbers would reintroduce the
    /// drift this replaces, so when the derivation is disabled it says nothing.
    @MainActor
    public static func coverageReport(
        ocr: any OCREngine,
        iMessageEnabled: Bool = false,
        browserHistoryEnabled: Bool = false,
        chatExportEnabled: Bool = false,
        mediaTranscriptionEnabled: Bool = false
    ) -> String? {
        guard KnowledgeModuleFlags.isEnabled(.generatedSourceCoverage) else { return nil }
        do {
            let rows = try coverage(
                ocr: ocr, iMessageEnabled: iMessageEnabled,
                browserHistoryEnabled: browserHistoryEnabled,
                chatExportEnabled: chatExportEnabled,
                mediaTranscriptionEnabled: mediaTranscriptionEnabled)
            let unclaimed = try unclaimedTypes(
                ocr: ocr, iMessageEnabled: iMessageEnabled,
                browserHistoryEnabled: browserHistoryEnabled,
                chatExportEnabled: chatExportEnabled,
                mediaTranscriptionEnabled: mediaTranscriptionEnabled)

            var lines: [String] = []
            var byLevel: [String: [TypeCoverage]] = [:]
            for r in rows { byLevel[r.level, default: []].append(r) }
            let order = ["FULL", "TEXT-ONLY", "CONTAINER", "DEFERRED", "PRESERVED-ONLY"]
            let counts = order.compactMap { lvl -> String? in
                guard let n = byLevel[lvl]?.count, n > 0 else { return nil }
                return "\(n) \(lvl)"
            }
            lines.append("FORMAT COVERAGE — derived from the parser registry as configured for this run.")
            lines.append(counts.joined(separator: " · "))
            for lvl in order {
                guard let group = byLevel[lvl], !group.isEmpty else { continue }
                let names = group.map { r -> String in
                    var n = r.type.rawValue
                    if r.requiresOCR { n += " (OCR)" }
                    if r.featureGated { n += " (opt-in)" }
                    return n
                }
                lines.append("\(lvl): \(names.joined(separator: ", "))")
            }
            lines.append("""
            What the words mean — FULL: typed, located evidence blocks, so structured facts \
            can be extracted. TEXT-ONLY: the text is read and fully searchable, but there is \
            no structural layer, so expect fewer facts. CONTAINER: expanded, and its members \
            are parsed on their own terms. DEFERRED: held with custody intact, interpretation \
            postponed. PRESERVED-ONLY: recognized and stored verbatim, not interpreted.
            """)
            if unclaimed.isEmpty {
                lines.append("Every declared source type has an owning parser.")
            } else {
                lines.append("""
                NOT READ — \(unclaimed.count) declared type(s) have no parser and fall back to a \
                generic text decode, which for a binary format yields little or nothing: \
                \(unclaimed.map(\.rawValue).joined(separator: ", ")).
                """)
            }
            return lines.joined(separator: "\n\n")
        } catch {
            // A coverage claim that could not be derived must say so. Returning a
            // partial or empty table here would read as "this is the coverage",
            // which is a statement this failed to establish.
            KalsmritikoshLog.ingestion.error(
                "Coverage report derivation failed: \(String(describing: error), privacy: .public)")
            return "FORMAT COVERAGE — could not be derived from the registry for this run "
                 + "(see log). No coverage claim is made rather than an unverified one."
        }
    }

    /// Opt-in adapters. Their loader is added only when the corresponding flag is
    /// set, so an ABSENT loader is the gate being closed — never a gap to fill in
    /// with the generic text reader.
    private static let featureGated: Set<SourceType> = [
        .imessage, .safariHistory, .chromeHistory, .chatExport
    ]

    private static func declaredSurfaces(for t: SourceType, hasStructural: Bool) -> Set<ContentSurfaceKind> {
        var s: Set<ContentSurfaceKind> = [.text]
        if hasStructural { s.formUnion([.structure, .metadata]) }
        switch t.category {
        case .spreadsheet: s.insert(.tables)
        case .image: s.insert(.images)
        case .email: s.formUnion([.attachments])
        default: break
        }
        if t == .pdf { s.insert(.images) }
        return s
    }
}
