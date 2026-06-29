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
        // Phase K — chat + browser ingest. Each loader is gated by
        // the user pointing FolderWatcher at the appropriate path
        // (~/Library/Messages, ~/Library/Safari, the Chromium
        // profile directory) AND having granted Full Disk Access
        // when applicable. No loader fires unless its source file
        // is explicitly under a bookmarked root.
        r.register(IMessageLoader())
        r.register(BrowserHistoryLoader())
        r.register(ChatExportLoader())
        return r
    }

    public nonisolated mutating func register(_ loader: any Ingestor) {
        for t in loader.supportedTypes { loaders[t] = loader }
    }

    public nonisolated func loader(for type: SourceType) -> any Ingestor {
        loaders[type] ?? unknownFallback
    }
}
