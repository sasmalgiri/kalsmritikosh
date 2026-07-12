//
//  MissingAttachmentTests.swift
//  KalsmritikoshTests
//
//  A5.7 — GapDetector.detectMissingAttachments: a message that references an
//  attachment but was ingested without one is a referenced-attachment gap;
//  negations and messages that DID carry an attachment are not. Add to the
//  test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct MissingAttachmentTests {

    @Test func referencedButMissingIsAGap() {
        let gaps = GapDetector().detectMissingAttachments(emails: [
            (objectID: UUID(), body: "Hi, please find attached the signed contract.", hasAttachment: false)
        ])
        #expect(gaps.count == 1)
        #expect(gaps.first?.kind == .referencedAttachment)
        // The reason is specific and states why it matters.
        #expect(gaps.first?.reason.contains("attached") == true)
        #expect(gaps.first?.confidence ?? 1 <= 0.5)
    }

    @Test func presentAttachmentIsNotAGap() {
        let gaps = GapDetector().detectMissingAttachments(emails: [
            (objectID: UUID(), body: "See attached invoice.", hasAttachment: true)
        ])
        #expect(gaps.isEmpty)
    }

    @Test func negationIsNotAGap() {
        let gaps = GapDetector().detectMissingAttachments(emails: [
            (objectID: UUID(), body: "There is no attachment on this one, text only.", hasAttachment: false)
        ])
        #expect(gaps.isEmpty)
    }

    @Test func noReferenceIsNotAGap() {
        let gaps = GapDetector().detectMissingAttachments(emails: [
            (objectID: UUID(), body: "Just a quick note, nothing else.", hasAttachment: false)
        ])
        #expect(gaps.isEmpty)
    }
}
