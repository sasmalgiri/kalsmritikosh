//
//  CloudReaders.swift
//  Kalsmritikosh
//
//  P1 (2026-11-03) — ONE place for the readers a brain may use beside the rules: the question
//  interpreter and rewriter (rules → on-device → the person's cloud reader), the verified record
//  extractor and the verified answer composer. The app builds them once (AppState, which owns the
//  Online provider) and installs the same set on the archive brain and on every case-scoped brain, so
//  a question asked inside a case is read the same way — with the case's own cloud scope bound by the
//  caller (MasterBrain.setCloudScope). Nothing here holds data or a model name: each reader is a
//  closure the caller injected. An empty set (offline, AI off, switches off) changes nothing.
//

import Foundation
import os

public nonisolated struct CloudReaders: Sendable {
    public var interpreterOnDevice: (any QuestionInterpreting)?
    public var interpreterCloud: (any QuestionInterpreting)?
    public var rewriterOnDevice: (any QuestionRewriting)?
    public var rewriterCloud: (any QuestionRewriting)?
    public var recordExtractor: VerifiedRecordExtractor?
    public var answerComposer: VerifiedAnswerComposer?
    /// The case bench measures the cloud readers with the AI regime forced on; nil in the app.
    public var modelsAllowedOverride: Bool?

    public init(interpreterOnDevice: (any QuestionInterpreting)? = nil, interpreterCloud: (any QuestionInterpreting)? = nil,
                rewriterOnDevice: (any QuestionRewriting)? = nil, rewriterCloud: (any QuestionRewriting)? = nil,
                recordExtractor: VerifiedRecordExtractor? = nil, answerComposer: VerifiedAnswerComposer? = nil,
                modelsAllowedOverride: Bool? = nil) {
        self.interpreterOnDevice = interpreterOnDevice; self.interpreterCloud = interpreterCloud
        self.rewriterOnDevice = rewriterOnDevice; self.rewriterCloud = rewriterCloud
        self.recordExtractor = recordExtractor; self.answerComposer = answerComposer
        self.modelsAllowedOverride = modelsAllowedOverride
    }

    public var isEmpty: Bool {
        interpreterOnDevice == nil && interpreterCloud == nil && rewriterOnDevice == nil && rewriterCloud == nil
            && recordExtractor == nil && answerComposer == nil && modelsAllowedOverride == nil
    }
}

/// The app's current reader set, readable synchronously from any context (the case-scoped brain
/// factory is a plain closure).
public final nonisolated class CloudReaderHolder: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: CloudReaders())
    public init() {}
    public var current: CloudReaders { state.withLock { $0 } }
    public func set(_ readers: CloudReaders) { state.withLock { $0 = readers } }
}
