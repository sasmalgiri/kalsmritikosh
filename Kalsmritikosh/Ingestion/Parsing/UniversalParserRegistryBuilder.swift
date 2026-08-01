//
//  UniversalParserRegistryBuilder.swift
//  Kalsmritikosh
//
//  USF-M1 (USF-003) — constructs the ONE immutable production registry. It is the single source of
//  routing truth: exactly one plugin owns each SourceType. The existing loader + structural-parser
//  instances are used here ONLY as construction inputs (their algorithms are untouched); at runtime
//  IngestCoordinator dispatches through the UniversalParserRegistry, never the old registries.
//  Feature-gated parsers remain feature-gated; media stays deferred (no transcription activated).
//

import Foundation

public enum UniversalParserRegistryBuilder {

    /// The complete production registry with injected dependencies. Immutable once built.
    @MainActor
    public static func standard(ocr: any OCREngine, iMessageEnabled: Bool = false,
                                browserHistoryEnabled: Bool = false, chatExportEnabled: Bool = false) throws -> UniversalParserRegistry {
        let structural = StructuralParserRegistry.standard(ocr: ocr)

        // Real content loaders (NOT AudioLoader/VideoLoader — media stays deferred; no transcription).
        var loaders: [any Ingestor] = [
            TextLoader(), PDFLoader(ocr: ocr), DocxLoader(), SpreadsheetLoader(), PresentationLoader(),
            EpubLoader(), EmailLoader(), ImageLoader(ocr: ocr), ArchiveLoader()
        ]
        if iMessageEnabled { loaders.append(IMessageLoader()) }
        if browserHistoryEnabled { loaders.append(BrowserHistoryLoader()) }
        if chatExportEnabled { loaders.append(ChatExportLoader()) }
        func realLoader(_ t: SourceType) -> (any Ingestor)? { loaders.first { $0.supportedTypes.contains(t) } }

        var plugins: [any UniversalParserPlugin] = []
        for t in SourceType.allCases where t != .unknown {
            let struc = structural.parser(for: t)
            switch t.category {
            case .audio, .video:
                // Recognized, custody kept, interpretation deferred — MMI will own transcription.
                plugins.append(PreservedOnlyPlugin(pluginID: "media.\(t.rawValue)", supportedTypes: [t], executionMode: .deferred))
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
                } else if let struc {
                    // Structural-only type (html/json/xml/log/sqlite): TextLoader reads the bytes; the
                    // STRUCTURE comes from the structural parser. Intentional text-fallback reader.
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
