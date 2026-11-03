//
//  PassageChronology.swift
//  Kalsmritikosh
//
//  G1 — "Add to case chronology" from a source passage (the Casefleet / CaseMap pattern: a fact is
//  made from the words on the page and stays linked to them). The passage travels as the entry's
//  citation (source version, document, block, quote), verified through the case's one evidence
//  verifier, the same way `JobResultHandoff.addToChronology` carries a reviewed row. The entry goes
//  through `CaseFileRepository.addJournal`, so a source outside the chosen case's scope is refused by
//  the repository — scope is never widened here — and the same passage added twice to the same case
//  is refused. A date is offered only when the passage states exactly one full calendar date;
//  otherwise it is left for the person to enter, never guessed.
//

import CryptoKit
import Foundation
import os

public nonisolated enum PassageChronologyError: Error, Equatable, LocalizedError {
    case emptyPassage
    case noSourceVersion
    case alreadyInChronology
    case outOfScope(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPassage:
            return "There is no passage to add — the cited words are empty."
        case .noSourceVersion:
            return "This passage's document has no recorded source version, so it can't be cited in a case. Nothing was added."
        case .alreadyInChronology:
            return "This passage is already in that case's chronology. Nothing was added; edit or retract the existing entry in the case file instead."
        case .outOfScope(let why):
            return "The case refused this passage: \(why). Nothing was added. Include the source in the case from the case file first if it belongs there."
        }
    }
}

/// What was recorded: the entry, the source version cited and how the passage verified.
public nonisolated struct PassageChronologyResult: Sendable, Equatable {
    public let entryID: UUID
    public let sourceVersionID: UUID
    public let citation: StudioEvidenceRef
    public let support: CaseEvidenceSupport
}

public nonisolated enum PassageChronology {
    /// The stable origin key of a passage in a case: (case, source version, block) — or, when the
    /// quote was not pinned to one block, a digest of the normalised quote in place of the block.
    public static func origin(caseID: UUID, sourceVersionID: UUID, blockID: UUID?, quote: String) -> String {
        let anchor: String
        if let blockID {
            anchor = "block:\(blockID.uuidString)"
        } else {
            let digest = SHA256.hash(data: Data(StudioEvidenceResolver.norm(quote).utf8)).map { String(format: "%02x", $0) }.joined()
            anchor = "quote:\(digest.prefix(32))"
        }
        return "passage:\(caseID.uuidString):\(sourceVersionID.uuidString):\(anchor)"
    }

    /// The one full calendar date the passage states (day, month and year), or nil when it states
    /// none, only a partial or relative one, a range, or more than one date — the person enters it then.
    @MainActor
    public static func suggestedDate(in passage: String) -> Date? {
        let text = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let match = DateGrammar.parse(text),
              let start = match.timeframe.start, let end = match.timeframe.end,
              end.timeIntervalSince(start) <= 86_400,
              match.evidence.range(of: #"\d{4}"#, options: .regularExpression) != nil else { return nil }
        // A second date phrase anywhere else in the passage ("from 3 March 2026 to 5 March 2026") makes
        // the date ambiguous: the person chooses.
        let rest = text.replacingOccurrences(of: match.evidence, with: " ", options: .caseInsensitive)
        guard DateGrammar.parse(rest) == nil else { return nil }
        let calendar = Calendar.current
        let days = Set(StudioEvidenceResolver.dates(in: text).map { calendar.startOfDay(for: $0) })
        guard days.count <= 1, days.allSatisfy({ calendar.isDate($0, inSameDayAs: start) }) else { return nil }
        return start
    }

    /// Record the passage as an investigator's chronology entry in the case. `sourceVersionID` and
    /// `blockID` are used when the caller has them; otherwise the version is found from the document
    /// and the block from the quoted words. Editing a case is a paid action (sample case exempt).
    @discardableResult
    public static func add(caseID: UUID, objectID: UUID?, sourceVersionID: UUID? = nil, blockID: UUID? = nil, quote: String,
                           text: String, eventDate: Date?, caseFiles: CaseFileService,
                           actor: String, at date: Date = Date()) async throws -> PassageChronologyResult {
        try PaidUse.require("edit the case file")
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { throw PassageChronologyError.emptyPassage }
        var version = sourceVersionID
        if version == nil, let objectID {
            version = try await caseFiles.file.sourceVersionToCite(objectID: objectID, caseID: caseID)
        }
        guard let version else { throw PassageChronologyError.noSourceVersion }
        let asked = StudioEvidenceRef(sourceVersionID: version, objectID: blockID == nil ? nil : objectID, blockID: blockID, quote: quote)
        var verification = await caseFiles.verify(reference: version.uuidString, passage: asked, caseID: caseID)
        // A block named by a caller that did not name the version (a search hit's own block) may belong to
        // another version of the source than the one the case cites: the same words are then looked for
        // in the cited version itself. The words are always checked; nothing is marked verified without them.
        if blockID != nil, sourceVersionID == nil, !verification.support.isDocumentary {
            let unpinned = StudioEvidenceRef(sourceVersionID: version, quote: quote)
            let retry = await caseFiles.verify(reference: version.uuidString, passage: unpinned, caseID: caseID)
            if retry.support.isDocumentary { verification = retry }
        }
        var citation = verification.passage ?? asked
        if citation.objectID == nil { citation.objectID = objectID }
        // What is stored is re-verified later (the case file, the report): it must verify the same way
        // now, so the label shown at add time is the one the report prints.
        if citation != (verification.passage ?? asked) {
            verification = await caseFiles.verify(reference: version.uuidString, passage: citation, caseID: caseID)
            if let p = verification.passage { citation = p }
        }
        let origin = Self.origin(caseID: caseID, sourceVersionID: version, blockID: citation.blockID, quote: quote)
        do {
            let id = try await caseFiles.file.addJournal(caseID: caseID, kind: .chronology, text: text, eventDate: eventDate,
                                                         evidenceRef: version.uuidString, quote: quote, origin: origin,
                                                         citations: [citation], support: verification.support,
                                                         actor: actor, at: date)
            return PassageChronologyResult(entryID: id, sourceVersionID: version, citation: citation, support: verification.support)
        } catch CaseFileError.alreadyCarried(_) {
            KalsmritikoshLog.app.info("Passage to chronology refused: already in the case")
            throw PassageChronologyError.alreadyInChronology
        } catch CaseFileError.unresolvedReference(_, let why) {
            KalsmritikoshLog.app.info("Passage to chronology refused: \(why, privacy: .public)")
            throw PassageChronologyError.outOfScope(why)
        }
    }

    /// The passage a chronology entry opens at: its first citation that names a document, else its
    /// evidence reference's version mapped to a document by `objectForVersion`. Nil when neither does.
    public static func openTarget(for entry: CaseJournalEntry, objectForVersion: [UUID: UUID]) -> (objectID: UUID, quote: String?)? {
        if let c = entry.citations.first(where: { $0.objectID != nil }), let o = c.objectID {
            return (o, c.quote ?? entry.quote)
        }
        for v in entry.citations.compactMap(\.sourceVersionID) {
            if let o = objectForVersion[v] { return (o, entry.citations.first { $0.sourceVersionID == v }?.quote ?? entry.quote) }
        }
        if let ref = entry.evidenceRef, case .sourceVersion(let v) = CaseEvidenceReference.parse(ref), let o = objectForVersion[v] {
            return (o, entry.quote)
        }
        return nil
    }
}
