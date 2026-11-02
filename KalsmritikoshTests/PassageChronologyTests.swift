//
//  PassageChronologyTests.swift
//  KalsmritikoshTests
//
//  G1 — "Add to case chronology" from a source passage: the entry carries the passage as its
//  citation (version, document, block, quote) and the source version as its evidence reference;
//  the same passage twice is refused; a source outside the case's scope is refused by the case;
//  a date is offered only when the passage states exactly one full date.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("G1 — add a source passage to the case chronology", .serialized)
struct PassageChronologyTests {

    static let text = "The board approved the payment on 3 March 2026. The treasurer resigned without notice."
    static let quote = "The board approved the payment on 3 March 2026."

    @Test("The entry carries the passage as its citation, the quote and the source version; the same passage twice is refused")
    func entryAndDuplicate() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt", text: Self.text)

        // From a citation: only the document and the words are known; version and block are resolved.
        let r = try await PassageChronology.add(caseID: f.caseID, objectID: src.object, quote: Self.quote, text: "Board approved the payment",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        #expect(r.sourceVersionID == src.version)
        #expect(r.support.isDocumentary, "\(r.support.label)")
        let entries = try await f.file.journal(caseID: f.caseID, kind: .chronology)
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.text == "Board approved the payment")
        #expect(e.evidenceRef == src.version.uuidString)
        #expect(e.quote == Self.quote)
        #expect(e.citations == [StudioEvidenceRef(sourceVersionID: src.version, objectID: src.object, blockID: src.blocks[0], quote: Self.quote)])
        #expect(e.origin == PassageChronology.origin(caseID: f.caseID, sourceVersionID: src.version, blockID: src.blocks[0], quote: Self.quote))
        #expect(e.support.isDocumentary)
        #expect(e.eventDate == nil)

        // The entry opens at its passage.
        let target = try #require(PassageChronology.openTarget(for: e, objectForVersion: [:]))
        #expect(target.objectID == src.object && target.quote == Self.quote)

        // The same passage again (even worded differently) is refused, with a clear message.
        await #expect(throws: PassageChronologyError.alreadyInChronology) {
            _ = try await PassageChronology.add(caseID: f.caseID, objectID: src.object, quote: Self.quote, text: "Approval recorded",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        }
        #expect(PassageChronologyError.alreadyInChronology.errorDescription?.contains("already in that case's chronology") == true)
        #expect(try await f.file.journal(caseID: f.caseID, kind: .chronology).count == 1)
    }

    @Test("A source outside the chosen case's scope is refused by the case; nothing is added and the scope is not widened")
    func outOfScopeRefused() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt", text: Self.text)
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Another matter", actor: "Ada", at: Date())

        await #expect(throws: PassageChronologyError.outOfScope("the source is not in this case's scope")) {
            _ = try await PassageChronology.add(caseID: other.id, objectID: src.object, quote: Self.quote, text: "Board approved the payment",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        }
        // The same refusal when the caller names the exact version and block.
        await #expect(throws: PassageChronologyError.outOfScope("the source is not in this case's scope")) {
            _ = try await PassageChronology.add(caseID: other.id, objectID: src.object, sourceVersionID: src.version, blockID: src.blocks[0],
                                                quote: Self.quote, text: "Board approved the payment",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        }
        #expect(try await f.file.journal(caseID: other.id, kind: .chronology).isEmpty)
        let scope = try await f.db.query("SELECT 1 FROM investigation_case_sources WHERE case_id = ?;", [.uuid(other.id)])
        #expect(scope.isEmpty, "the source was not added to the other case")
        // A document with no source version at all cannot be cited.
        await #expect(throws: PassageChronologyError.noSourceVersion) {
            _ = try await PassageChronology.add(caseID: f.caseID, objectID: UUID(), quote: Self.quote, text: "x",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        }
    }

    @Test("A date is read only when the passage states exactly one full date; otherwise it is left empty")
    @MainActor
    func suggestedDate() throws {
        #expect(PassageChronology.suggestedDate(in: "The treasurer resigned without notice.") == nil)
        #expect(PassageChronology.suggestedDate(in: "The payment was approved in March 2026.") == nil, "a month is not a date")
        #expect(PassageChronology.suggestedDate(in: "Approved on 3 March.") == nil, "no year: not guessed")
        #expect(PassageChronology.suggestedDate(in: "Work ran from 3 March 2026 to 5 March 2026.") == nil, "a range is not one date")
        #expect(PassageChronology.suggestedDate(in: "Approved on 3 March 2026; paid on 9 April 2026.") == nil, "two dates: the person chooses")
        let d = try #require(PassageChronology.suggestedDate(in: Self.quote))
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        #expect(c.year == 2026 && c.month == 3 && c.day == 3)
    }
}
