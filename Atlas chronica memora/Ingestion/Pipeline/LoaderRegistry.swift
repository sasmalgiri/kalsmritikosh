//
//  LoaderRegistry.swift
//  Atlas chronica memora
//
//  Maps SourceType to the right Ingestor. Adding a new loader is a
//  one-line registration. Used by IngestCoordinator to fan out files
//  to the correct parser.
//

import Foundation

public struct LoaderRegistry: Sendable {
    private var loaders: [SourceType: any Ingestor] = [:]
    private let unknownFallback: any Ingestor

    public init(unknownFallback: any Ingestor = TextLoader()) {
        self.unknownFallback = unknownFallback
    }

    public static func standard() -> LoaderRegistry {
        var r = LoaderRegistry()
        r.register(TextLoader())
        r.register(PDFLoader())
        r.register(DocxLoader())
        r.register(SpreadsheetLoader())
        r.register(PresentationLoader())
        r.register(EmailLoader())
        r.register(ImageLoader())
        r.register(AudioLoader())
        r.register(VideoLoader())
        r.register(ArchiveLoader())
        return r
    }

    public mutating func register(_ loader: any Ingestor) {
        for t in loader.supportedTypes { loaders[t] = loader }
    }

    public func loader(for type: SourceType) -> any Ingestor {
        loaders[type] ?? unknownFallback
    }
}
