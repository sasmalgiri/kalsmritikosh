//
//  TranscriptSegment.swift
//  Kalsmritikosh
//
//  Persona features (F8). One timecoded, reviewable line of a transcript.
//  Times are seconds from the start of the media so a quote can jump to the
//  exact moment. Speaker is user-assignable (no on-device diarization);
//  low-confidence ASR must stay visible and is never treated as directly
//  observed fact (§13).
//

import Foundation

public struct TranscriptSegment: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public let sourceFileID: UUID
    public let sourceURL: String
    public var ordinal: Int
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var speakerConfidence: Double?
    public var text: String
    public var asrConfidence: Double
    public var reviewState: String
    public var markedQuote: Bool
    public var engine: String
    public let createdAt: Date

    public nonisolated init(
        id: ID = UUID(),
        sourceFileID: UUID,
        sourceURL: String,
        ordinal: Int,
        start: Double,
        end: Double,
        speaker: String? = nil,
        speakerConfidence: Double? = nil,
        text: String,
        asrConfidence: Double = 0,
        reviewState: String = "unreviewed",
        markedQuote: Bool = false,
        engine: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceFileID = sourceFileID
        self.sourceURL = sourceURL
        self.ordinal = ordinal
        self.start = start
        self.end = end
        self.speaker = speaker
        self.speakerConfidence = speakerConfidence
        self.text = text
        self.asrConfidence = asrConfidence
        self.reviewState = reviewState
        self.markedQuote = markedQuote
        self.engine = engine
        self.createdAt = createdAt
    }

    /// "mm:ss" (or "h:mm:ss") for the segment start — the display + jump anchor.
    public var startTimecode: String { Self.timecode(start) }

    public static func timecode(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
