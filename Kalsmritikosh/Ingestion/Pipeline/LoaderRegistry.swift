//
//  LoaderRegistry.swift
//  Kalsmritikosh
//
//  Maps SourceType to the right Ingestor. Adding a new loader is a
//  one-line registration. Used by IngestCoordinator to fan out files
//  to the correct parser.
//

import Foundation

public struct LoaderRegistry: Sendable {
    private var loaders: [SourceType: any Ingestor] = [:]
    private let unknownFallback: any Ingestor

    public nonisolated init(unknownFallback: any Ingestor = TextLoader()) {
        self.unknownFallback = unknownFallback
    }

    /// Default registry built from the always-on loaders only. The
    /// optional chat + browser loaders are added by
    /// `standard(flags:)` when the corresponding feature flag is
    /// enabled. App Store builds initialize via the parameterless
    /// `standard()` so the optional loaders are absent until the
    /// user opts in via Settings.
    public nonisolated static func standard() -> LoaderRegistry {
        var r = LoaderRegistry()
        r.register(TextLoader())
        r.register(PDFLoader())
        r.register(DocxLoader())
        r.register(SpreadsheetLoader())
        r.register(PresentationLoader())
        r.register(EpubLoader())
        r.register(EmailLoader())
        r.register(ImageLoader())
        r.register(AudioLoader())
        r.register(VideoLoader())
        r.register(ArchiveLoader())
        return r
    }

    /// Phase L — registry built with flag-gated optional loaders.
    /// AppState calls this once at boot, passing the current
    /// FeatureFlags snapshot. Disabled loaders are simply not
    /// registered, so a file matching their detection pattern
    /// (chat.db, History.db) falls back to the unknownFallback
    /// (TextLoader) — i.e. it's read as raw text, no Messages /
    /// browser API access attempted.
    public nonisolated static func standard(
        iMessageEnabled: Bool,
        browserHistoryEnabled: Bool,
        chatExportEnabled: Bool
    ) -> LoaderRegistry {
        var r = standard()
        if iMessageEnabled {
            r.register(IMessageLoader())
        }
        if browserHistoryEnabled {
            r.register(BrowserHistoryLoader())
        }
        if chatExportEnabled {
            r.register(ChatExportLoader())
        }
        return r
    }

    public nonisolated mutating func register(_ loader: any Ingestor) {
        for t in loader.supportedTypes { loaders[t] = loader }
    }

    public nonisolated func loader(for type: SourceType) -> any Ingestor {
        loaders[type] ?? unknownFallback
    }
}
