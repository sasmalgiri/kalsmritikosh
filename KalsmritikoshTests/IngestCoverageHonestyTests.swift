//
//  IngestCoverageHonestyTests.swift
//  KalsmritikoshTests
//
//  Ingest coverage feeds ANSWER CONFIDENCE: the engine multiplies the boost
//  ceiling by `max(coverage, 0.5)` while coverage < 1.0. So a coverage of 1.0
//  means "the whole archive is ingested — apply no downgrade".
//
//  The defect this pins: the provider returned 1.0 when it could not measure.
//  A throwing repository count, or one already deallocated, arrived as a
//  fully-ingested archive and granted the full confidence boost at exactly the
//  moment the system knew least about its own completeness.
//
//  The distinction that has to hold: "nothing to measure" (an empty archive,
//  where coverage really is trivially complete) is NOT the same as "could not
//  measure".
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Ingest coverage distinguishes unknown from complete")
struct IngestCoverageHonestyTests {

    @Test("An unmeasurable file count is unknown, NOT a fully ingested archive")
    func unmeasurableFileCountIsUnknown() {
        // The denominator is unknown, so the fraction is. This used to return
        // 1.0 and hand the engine its full boost.
        #expect(EvidenceVerifier.ingestCoverage(fileCount: nil, objectCount: 40) == nil)
        #expect(EvidenceVerifier.ingestCoverage(fileCount: nil, objectCount: nil) == nil)
    }

    @Test("An unmeasurable object count is unknown, not zero coverage either")
    func unmeasurableObjectCountIsUnknown() {
        // The other direction matters too: treating a failed numerator as 0
        // would report "nothing is ingested" and halve confidence on a
        // transient failure — a different lie, not a fix.
        #expect(EvidenceVerifier.ingestCoverage(fileCount: 100, objectCount: nil) == nil)
    }

    @Test("A genuinely EMPTY archive is complete coverage — the one honest 1.0")
    func emptyArchiveIsTriviallyComplete() {
        // Zero files means nothing is un-ingested, so coverage is complete
        // without needing to measure objects at all. This is the only case
        // where 1.0 is true rather than optimistic.
        #expect(EvidenceVerifier.ingestCoverage(fileCount: 0, objectCount: nil) == 1.0)
        #expect(EvidenceVerifier.ingestCoverage(fileCount: 0, objectCount: 0) == 1.0)
    }

    @Test("A measured partial ingest reports its real fraction")
    func partialIngestReportsItsFraction() {
        #expect(EvidenceVerifier.ingestCoverage(fileCount: 100, objectCount: 40) == 0.4)
        #expect(EvidenceVerifier.ingestCoverage(fileCount: 4, objectCount: 4) == 1.0)
        #expect(EvidenceVerifier.ingestCoverage(fileCount: 3, objectCount: 0) == 0.0)
    }

    @Test("A dirty count above the file total clamps to 1.0 rather than exceeding it")
    func overCountClamps() {
        // More objects than files is possible (an mbox yields many KOs from one
        // file), and a coverage above 1.0 would be meaningless.
        #expect(EvidenceVerifier.ingestCoverage(fileCount: 10, objectCount: 250) == 1.0)
    }

    @Test("The unknown floor cannot inflate confidence")
    func unknownFloorIsConservative() {
        // Not a new number: the engine already clamps at max(coverage, 0.5) for
        // an incomplete ingest, so unknown takes that same floor. The property
        // that matters is that it is strictly below the no-downgrade value.
        #expect(EvidenceVerifier.unknownIngestCoverage == 0.5)
        #expect(EvidenceVerifier.unknownIngestCoverage < 1.0)
    }
}
