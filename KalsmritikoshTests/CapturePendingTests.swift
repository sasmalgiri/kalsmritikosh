//
//  CapturePendingTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (IN-13, IN-14): field capture waits for confirmation — a pending item with its preview (image
//  regions or transcript times), corrected and selected by the person; admission keeps the original byte for byte and the
//  checked text beside it; discarding adds nothing; the same bytes are never added twice; pending items survive a restart.
//  The preview lines are given directly (the on-device recognisers are not run in the test host).
//

import Foundation
import CoreGraphics
import Testing
@testable import Kalsmritikosh

@Suite("Capture — pending until checked", .serialized)
struct CapturePendingTests {
    func inbox() -> (CapturePendingInbox, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-pending-\(UUID().uuidString)", isDirectory: true)
        return (CapturePendingInbox(root: dir.appendingPathComponent("pending")), dir.appendingPathComponent("intake"))
    }
    func save(into dir: URL) -> (Data, String, String) throws -> URL {
        { data, name, _ in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent(name); try data.write(to: u); return u
        }
    }

    @Test("A photo: a wrong digit corrected, a line left out; the original is added unchanged and the checked text beside it")
    func photoCorrectedAndAdmitted() throws {
        let (box, intake) = inbox()
        let bytes = Data("fake-jpeg-bytes".utf8)
        let item = try box.receive(bytes, name: "receipt.jpg", origin: "drop")
        #expect(item.kind == .image && item.state == .pending)
        let ocr = [OCRLine(text: "Total INR 5O,000", confidence: 0.42, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05)),
                   OCRLine(text: "Thank you for shopping", confidence: 0.95, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.05))]
        try box.setPreview(item.id, lines: CapturePreview.lines(fromOCR: ocr), note: nil)
        try box.edit(item.id, line: 0, corrected: "Total INR 50,000", kept: true)
        try box.edit(item.id, line: 1, corrected: nil, kept: false)
        // A restart: the manifest on disk still holds the pending item with its edits.
        let reopened = CapturePendingInbox(root: box.root)
        let waiting = try #require(reopened.items().first)
        #expect(waiting.state == .pending && waiting.lines[0].text == "Total INR 50,000" && !waiting.lines[1].kept)
        let r = try reopened.admit(item.id, save: save(into: intake))
        #expect(try Data(contentsOf: r.original) == bytes, "the original is byte for byte")
        let text = try String(contentsOf: try #require(r.text), encoding: .utf8)
        #expect(text.contains("Total INR 50,000") && text.contains("Total INR 5O,000 → Total INR 50,000") && !text.contains("Thank you"), "\(text)")
        #expect(text.contains("1 recognised line(s) were left out") && text.contains("region 0.10,0.20"))
        #expect(reopened.items().first?.state == .admitted)
        #expect(throws: CapturePendingError.duplicate("in the archive")) { try reopened.receive(bytes, name: "receipt copy.jpg", origin: "drop") }
    }

    @Test("A recording: an uncertain speaker corrected by its time; a discarded item adds nothing; a duplicate while pending is refused")
    func recordingAndDiscard() throws {
        let (box, intake) = inbox()
        let audio = try box.receive(Data("fake-m4a".utf8), name: "interview.m4a", origin: "drop")
        #expect(audio.kind == .audio)
        #expect(throws: CapturePendingError.duplicate("waiting in Capture")) { try box.receive(Data("fake-m4a".utf8), name: "again.m4a", origin: "drop") }
        let segs = [ASRSegment(start: 12, end: 18, text: "Speaker 2: I signed it on Friday", confidence: 0.4)]
        try box.setPreview(audio.id, lines: CapturePreview.lines(fromTranscript: segs), note: nil)
        try box.edit(audio.id, line: 0, corrected: "Meera Shah: I signed it on Friday", kept: true)
        let r = try box.admit(audio.id, save: save(into: intake))
        let text = try String(contentsOf: try #require(r.text), encoding: .utf8)
        #expect(text.contains("[00:12–00:18] Meera Shah: I signed it on Friday") && text.contains("Speaker 2: I signed it on Friday → Meera Shah"), "\(text)")
        let video = try box.receive(Data("fake-mov".utf8), name: "site.mov", origin: "drop")
        try box.discard(video.id)
        #expect(box.items().first { $0.id == video.id }?.state == .discarded)
        #expect(!FileManager.default.fileExists(atPath: intake.appendingPathComponent("site.mov").path))
        #expect(throws: CapturePendingError.notPending) { try box.admit(video.id, save: save(into: intake)) }
        // A file with no preview is added as it is; all lines left out refuses (keep one, or the item has no text).
        let photo = try box.receive(Data("p".utf8), name: "p.png", origin: "drop")
        try box.setPreview(photo.id, lines: [CapturePendingItem.Line(id: 0, recognised: "x", confidence: 1, locator: "region 0,0,1,1", kept: false)], note: nil)
        #expect(throws: CapturePendingError.nothingKept) { try box.admit(photo.id, save: save(into: intake)) }
    }
}
