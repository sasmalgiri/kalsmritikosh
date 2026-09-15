//
//  FileIndexStatusTests.swift
//  KalsmritikoshTests
//
//  U-3.6 (W-6) — every file gets an honest status. Pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-3.6 file index status")
struct FileIndexStatusTests {

    @Test func textFileWithChunksIsIndexed() {
        #expect(FileIndexStatus.classify(sourceType: .pdf, chunkCount: 12) == .indexed)
        #expect(FileIndexStatus.classify(sourceType: .eml, chunkCount: 3) == .indexed)
    }

    @Test func textFileWithNoChunksIsUnsupported() {
        #expect(FileIndexStatus.classify(sourceType: .pdf, chunkCount: 0) == .unsupported)
    }

    @Test func imageIsLimitedScanOrUnsupported() {
        #expect(FileIndexStatus.classify(sourceType: .jpg, chunkCount: 2) == .limitedScan)
        #expect(FileIndexStatus.classify(sourceType: .png, chunkCount: 0) == .unsupported)
    }

    @Test func audioVideoTranscriptionStates() {
        #expect(FileIndexStatus.classify(sourceType: .mp3, chunkCount: 5) == .transcribed)
        #expect(FileIndexStatus.classify(sourceType: .threegp, chunkCount: 0) == .notTranscribed)
        #expect(FileIndexStatus.classify(sourceType: .mp4, chunkCount: 0) == .notTranscribed)
    }

    @Test func archiveExpansionStates() {
        #expect(FileIndexStatus.classify(sourceType: .zip, chunkCount: 0, expandedMemberCount: 8) == .expanded)
        #expect(FileIndexStatus.classify(sourceType: .zip, chunkCount: 0, expandedMemberCount: 0) == .notExpanded)
    }

    @Test func everySourceTypeClassifiesToAStatus() {
        // Coverage: no SourceType falls through — every file in the Sources
        // format table gets a status (the acceptance).
        for t in SourceType.allCases {
            let s = FileIndexStatus.classify(sourceType: t, chunkCount: 1, expandedMemberCount: 1)
            #expect(!s.label.isEmpty, "\(t) produced no status")
        }
    }
}
