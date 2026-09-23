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

public enum UniversalParserRegistryBuilder {

    /// The complete production registry with injected dependencies. Immutable once built.
    @MainActor
    public static func standard(ocr: any OCREngine, iMessageEnabled: Bool = false,
                                browserHistoryEnabled: Bool = false, chatExportEnabled: Bool = false,
                                mediaTranscriptionEnabled: Bool = false) throws -> UniversalParserRegistry {
        let structural = StructuralParserRegistry.standard(ocr: ocr)

        // Real content loaders. Audio/video join only when transcription is enabled (below).
        var loaders: [any Ingestor] = [
            TextLoader(), PDFLoader(ocr: ocr), DocxLoader(), SpreadsheetLoader(), PresentationLoader(),
            EpubLoader(), EmailLoader(), ImageLoader(ocr: ocr), ArchiveLoader(), PlistLoader(), RegistryHiveLoader(),
            SQLiteLoader(), DiscussionExportLoader(), CustodyManifestLoader(),
            EVTXLoader()
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
            let transcriber = SpeechTranscriber()
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
