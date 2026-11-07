//
//  VisionCancellationTests.swift
//  KalsmritikoshTests
//
//  Autonomous completion mandate 2026-11-01, N8 — Apple documents VNRequest.cancel(); the earlier claim
//  that a Vision request "cannot be cancelled" was wrong. These tests measure, on this Mac, that
//  cancelling the task cancels the request in flight and stops the retries, that a cancellation is not
//  counted as a recognition failure, and that failures are attributed to the document that had them —
//  not to whichever document happened to be reading at the same time.
//

import Foundation
import Testing
import AppKit
import Vision
@testable import Kalsmritikosh

@Suite("N8 — Vision cancellation and per-document attribution", .serialized)
struct VisionCancellationTests {
    init() {
        // What a launch does: a cache marked incomplete is rebuilt before any recognition.
        VisionPerform.rebuildCompiledModelCacheIfMarked()
    }

    /// A large page of dense text, so an accurate recognition takes long enough to cancel mid-way.
    static func densePage(width: Int = 2400, height: Int = 3200) -> CGImage? {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
        var y = height - 40
        var n = 0
        while y > 20 {
            ("Line \(n): The invoice of 4 March was paid twice to the same supplier account, reference INV-\(1000 + n)." as NSString)
                .draw(at: NSPoint(x: 30, y: y), withAttributes: attrs)
            y -= 30; n += 1
        }
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func request() -> VNRecognizeTextRequest {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.recognitionLanguages = ["en-US"]
        return r
    }

    @Test("Failures are charged to the document that had them, even while another document reads at the same time")
    func attribution() async throws {
        let page = try #require(Self.densePage(width: 400, height: 200))
        let failing = VisionPerform.Tally(), clean = VisionPerform.Tally()
        async let a: Bool = VisionPerform.$forceFailureForTesting.withValue(true) {
            await VisionPerform.tallying(failing) { VisionPerform.perform(Self.request(), cgImage: page, orientation: .up) }
        }
        async let b: Bool = VisionPerform.tallying(clean) { VisionPerform.perform(Self.request(), cgImage: page, orientation: .up) }
        let (ra, rb) = await (a, b)
        #expect(!ra && failing.failed == 1, "the failing document records its own failure")
        #expect(rb && clean.failed == 0, "the other document is not charged with it")
    }

    @Test("Cancelling the task cancels the Vision request in flight: it returns early, retries nothing and is not counted as a failure")
    func cancellation() async throws {
        let page = try #require(Self.densePage())
        // Baseline: how long one uncancelled recognition of this page takes here.
        let start = ContinuousClock.now
        let baseline = VisionPerform.Tally()
        let ok = await VisionPerform.tallying(baseline) { VisionPerform.perform(Self.request(), cgImage: page, orientation: .up) }
        let full = ContinuousClock.now - start
        #expect(ok && baseline.failed == 0)
        print("N8 vision baseline: uncancelled recognition took \(full)")
        guard full > .milliseconds(400) else {
            print("N8 vision: recognition finished in \(full) — too fast on this Mac to cancel mid-way")
            return
        }
        // Cancel 150 ms into the same work.
        let tally = VisionPerform.Tally()
        let t0 = ContinuousClock.now
        let task = Task { await VisionPerform.tallying(tally) { VisionPerform.perform(Self.request(), cgImage: page, orientation: .up) } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - t0
        print("N8 vision cancel: cancelled after 150 ms; returned after \(elapsed) (uncancelled: \(full)); result \(result), cancelled \(tally.cancelled), failed \(tally.failed)")
        #expect(!result, "a cancelled recognition reports no text")
        #expect(tally.failed == 0 && tally.cancelled == 1, "a cancellation is not a recognition failure")
        #expect(elapsed < full, "VNRequest.cancel() stopped the work before it would have finished")
    }

    @Test("A task already cancelled starts no recognition at all")
    func cancelledBeforeStart() async throws {
        let page = try #require(Self.densePage(width: 400, height: 200))
        let tally = VisionPerform.Tally()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await VisionPerform.tallying(tally) { VisionPerform.perform(Self.request(), cgImage: page, orientation: .up) }
        }
        #expect(await task.value == false && tally.cancelled == 1 && tally.failed == 0)
    }
}
