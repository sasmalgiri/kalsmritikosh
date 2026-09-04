//
//  StorySourceContext.swift
//  Kalsmritikosh
//
//  P4-U2 (GO 2 REVISED) — the per-source facts the H-laws place chapters by:
//  which email thread a source belongs to (H-5: episodes over threads) and
//  its document class (H-3: certificate-class documents contribute WHOLE-FILE
//  beats — their record is never split across chapters). Resolved from the
//  ledger by the engine's optional provider; an empty context reproduces the
//  original year-bucket outline byte for byte.
//

import Foundation

public nonisolated struct StorySourceContext: Sendable {
    /// Source object → its episode key (the thread's normalized subject).
    public let episodeKeyByObject: [KnowledgeObject.ID: String]
    /// Episode key → the display subject shown as the chapter title.
    public let episodeDisplayByKey: [String: String]
    /// Source object → its document class raw value (v123 column).
    public let documentClassByObject: [KnowledgeObject.ID: String]

    public static let empty = StorySourceContext(
        episodeKeyByObject: [:], episodeDisplayByKey: [:], documentClassByObject: [:])

    public var isEmpty: Bool {
        episodeKeyByObject.isEmpty && documentClassByObject.isEmpty
    }

    public nonisolated init(episodeKeyByObject: [KnowledgeObject.ID: String],
                            episodeDisplayByKey: [String: String],
                            documentClassByObject: [KnowledgeObject.ID: String]) {
        self.episodeKeyByObject = episodeKeyByObject
        self.episodeDisplayByKey = episodeDisplayByKey
        self.documentClassByObject = documentClassByObject
    }

    /// The classes whose documents beat as ONE unit (H-3). Data, not code.
    public static let wholeFileClasses: Set<String> = [
        DocumentClass.certificate.rawValue,
        DocumentClass.legalDocument.rawValue,
    ]
}
