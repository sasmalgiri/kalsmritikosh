//
//  AIAssist.swift
//  Kalsmritikosh
//
//  A5–A7 (completion mandate 2026-11-01) — three Online-AI helps that work only from the person's own
//  documents and always say what they are:
//
//   • A5 Translate with AI — a document's text into English, added as its own marked document that
//     cites the original (the original is never replaced; v1 reads and answers in English).
//   • A6 Challenge this answer — the AI argues AGAINST an answer from the passages it was built on:
//     gaps, alternative explanations, passages that do not support it, what would settle it. It is a
//     review, never a finding and never a conclusion (the owner's rule: no auto-conclusions).
//   • A7 Draft from this answer — a neutral report paragraph from the same passages, every sentence
//     cited, for the person to edit; never filed on its own.
//
//  Every request is a document send: the documents are cleared by CloudSourceGate first (privileged,
//  above-confidential or unresolvable ones are refused), previewed, recorded, and re-checked at the send
//  boundary — the same path as an Online answer. Every [P#] in what comes back is checked against the
//  passages actually sent; a sentence with no citation, or a citation to nothing sent, is flagged.
//

import Foundation
import os

nonisolated enum AIAssist {
    /// One passage sent, with the label the AI must cite.
    struct Passage: Equatable, Sendable {
        let label: String        // "P1"
        let objectID: UUID
        let source: String       // file name
        let text: String
    }

    /// What came back, with the citation check.
    struct Review: Equatable, Sendable {
        let kind: String
        let text: String
        let passages: [Passage]
        /// Labels cited that were not sent (the AI made them up).
        let unknownCitations: [String]
        /// Sentences carrying no citation at all.
        let uncitedSentences: [String]
        var isFullyCited: Bool { unknownCitations.isEmpty && uncitedSentences.isEmpty }
    }

    /// Longest passage text sent per request (stays inside AI Included's input limit with room to spare).
    static let maxPromptChars = 90_000
    /// Translation is sent in parts of about this size, each previewed.
    static let translationPartChars = 12_000

    static func label(_ citations: [(objectID: UUID, source: String, text: String)]) -> [Passage] {
        var out: [Passage] = []
        var used = 0
        for c in citations {
            let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !out.contains(where: { $0.objectID == c.objectID && $0.text == t }) else { continue }
            guard used + t.count <= maxPromptChars else { break }
            used += t.count
            out.append(Passage(label: "P\(out.count + 1)", objectID: c.objectID, source: c.source, text: t))
        }
        return out
    }

    static func passageBlock(_ passages: [Passage]) -> String {
        passages.map { "[\($0.label)] (\($0.source))\n\($0.text)" }.joined(separator: "\n\n")
    }

    static func challengePrompt(question: String, answer: String, passages: [Passage]) -> String {
        """
        An investigator's working answer is below, with the only passages it was built on. Review it critically — your job is to find what could be wrong with it, not to agree with it and not to reach a conclusion of your own.

        Using ONLY these passages, write four short sections:
        1. Weaknesses or gaps in the answer.
        2. Other explanations the passages are equally consistent with.
        3. Passages that contradict the answer or do not actually support it.
        4. What further evidence would settle it.
        Cite every point with the passage label in square brackets, e.g. [P2]. If the passages say nothing on a point, write "The passages do not say." Do not invent facts, names, dates or passages.

        Question: \(question)

        Working answer: \(answer)

        Passages:
        \(passageBlock(passages))
        """
    }

    static func draftPrompt(question: String, answer: String, passages: [Passage]) -> String {
        """
        Draft one neutral, factual paragraph for a case report on the question below, using ONLY these passages. Every sentence must end with the label(s) of the passage(s) it rests on in square brackets, e.g. [P1][P3]. Report what the documents say and who says it; do not speculate, characterise motives or reach conclusions the passages do not state. Where the passages are silent, write "The documents do not say." The investigator's working answer is given for orientation only — do not repeat anything from it that the passages do not support.

        Question: \(question)

        Working answer: \(answer)

        Passages:
        \(passageBlock(passages))
        """
    }

    static func translationPrompt(fileName: String, part: Int, of parts: Int, text: String) -> String {
        """
        Translate the following text from “\(fileName)” (part \(part) of \(parts)) into English. Translate everything, faithfully and completely: keep names, numbers, dates, amounts, and the paragraph and line structure; do not summarise, explain, correct or add anything. Leave text that is already English as it is. Mark anything you cannot translate with confidence as [uncertain: original words].

        \(text)
        """
    }

    /// Split `text` into parts near `size`, at paragraph or line breaks where possible.
    static func parts(of text: String, size: Int = translationPartChars) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while rest.count > size {
            let window = rest.prefix(size)
            let cut = window.range(of: "\n\n", options: .backwards)?.upperBound
                ?? window.range(of: "\n", options: .backwards)?.upperBound
                ?? window.endIndex
            out.append(String(rest[rest.startIndex..<cut]))
            rest = rest[cut...]
        }
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(String(rest)) }
        return out
    }

    /// Check every citation in `text` against the passages sent.
    static func review(kind: String, text: String, passages: [Passage]) -> Review {
        let known = Set(passages.map(\.label))
        let cited = matches(of: #"\[(P\d+)\]"#, in: text)
        let unknown = Array(Set(cited.filter { !known.contains($0) })).sorted()
        // A sentence is a run of text ending in . ! or ? (or a line); headings and "do not say" lines need no citation.
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "\n"))
            .flatMap { $0.split(separator: ".", omittingEmptySubsequences: true).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { s in
                s.count > 40 && !s.contains("[P") && !s.lowercased().contains("do not say")
                    && !s.hasSuffix(":") && s.first?.isNumber != true
            }
        return Review(kind: kind, text: text, passages: passages, unknownCitations: unknown, uncitedSentences: sentences)
    }

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The translation document's text: a header that says exactly what it is, then the translation.
    static func translationDocument(original: String, originalObjectID: UUID, provider: String, model: String,
                                    at date: Date, body: String) -> String {
        """
        AI TRANSLATION INTO ENGLISH — NOT THE ORIGINAL DOCUMENT
        Original: \(original) (document \(originalObjectID.uuidString))
        Translated by: \(provider), model \(model), on \(ISO8601DateFormatter().string(from: date))
        This English text was produced by an AI model. Quote the original, not this translation, and check names, numbers, dates and meaning against it before relying on it. [uncertain: …] marks what the model could not translate with confidence.

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }
}

// MARK: - The sends

extension AppState {

    enum AIAssistError: Error, LocalizedError {
        case unavailable(String), nothingCleared(Int), empty
        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            case .nothingCleared(let denied): return "None of the documents may go to the cloud (\(denied) refused: privileged, above confidential, or not traceable). Nothing was sent."
            case .empty: return "There is no text to send."
            }
        }
    }

    /// The Online provider, if a document send can run now; otherwise why not.
    private func assistProvider() async throws -> OnlineCloudProvider {
        guard PurchaseCenter.shared.allowPaidAction("analyse with AI") else { throw PaidUse.Refused(what: "analyse with AI", reason: PaidUse.refusal("analyse with AI")?.reason ?? "A subscription is needed.") }
        guard OnlineSettings.cloudAllowed else {
            throw AIAssistError.unavailable(AIRegion.current.explanation ?? "This needs Online mode: switch it on in Settings ▸ Modules and choose AI Included or your own provider.")
        }
        guard let provider = onlineProvider, await provider.isAvailable() else { throw OnlineCloudProvider.OnlineError.notAvailable }
        return provider
    }

    /// Clear `objectIDs` for a cloud send; only cleared documents' passages may be used.
    private func clearForCloud(_ objectIDs: [UUID], purpose: String) async throws -> CloudSourceClearance {
        guard let scopes = sensitiveScopes else { throw AIAssistError.unavailable("The ledger is not open yet.") }
        let (clearance, denied) = await CloudSourceGate(sensitiveScope: scopes, objects: objects).clear(Array(Set(objectIDs)), purpose: purpose)
        guard !clearance.clearedObjectIDs.isEmpty else { throw AIAssistError.nothingCleared(denied.count) }
        return clearance
    }

    /// A6 / A7 — challenge or draft from an answer's own cited passages.
    func reviewAnswerWithAI(_ answer: VerifiedAnswer, question: String, draft: Bool) async throws -> AIAssist.Review {
        let provider = try await assistProvider()
        let ids = answer.citations.map(\.objectID)
        let clearance = try await clearForCloud(ids, purpose: draft ? "assist.draft" : "assist.challenge")
        let names = (try? await objects?.sourceFilenames(for: Set(ids))) ?? [:]
        let passages = AIAssist.label(answer.citations
            .filter { clearance.clearedObjectIDs.contains($0.objectID) }
            .map { (objectID: $0.objectID, source: names[$0.objectID] ?? "document", text: $0.snippet) })
        guard !passages.isEmpty else { throw AIAssistError.empty }
        let body = answer.answerText ?? answer.body
        let prompt = draft ? AIAssist.draftPrompt(question: question, answer: body, passages: passages)
                           : AIAssist.challengePrompt(question: question, answer: body, passages: passages)
        let text = try await provider.generateFromDocuments(prompt: prompt, options: GenerationOptions(maxTokens: 3_000, sourceClearance: clearance))
        return AIAssist.review(kind: draft ? "AI draft — edit and check before use" : "AI challenge — a review, not a finding",
                               text: text, passages: passages)
    }

    /// A5 — translate one document into English and add the translation as its own marked document.
    func translateWithAI(objectID: UUID) async -> String {
        do {
            let provider = try await assistProvider()
            guard let ingest, let objects else { return "The ledger is not open yet." }
            let clearance = try await clearForCloud([objectID], purpose: "assist.translate")
            guard let text = try await objects.fetchContent(id: objectID), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIAssistError.empty }
            let name = (try? await objects.load(id: objectID))?.sourceFile.lastPathComponent ?? "document"
            let parts = AIAssist.parts(of: text)
            var out: [String] = []
            for (i, part) in parts.enumerated() {
                out.append(try await provider.generateFromDocuments(
                    prompt: AIAssist.translationPrompt(fileName: name, part: i + 1, of: parts.count, text: part),
                    options: GenerationOptions(maxTokens: 4_000, sourceClearance: clearance)))
            }
            let s = OnlineSnapshot.current()
            let doc = AIAssist.translationDocument(original: name, originalObjectID: objectID, provider: s.kind.displayName,
                                                   model: s.model, at: Date(), body: out.joined(separator: "\n\n"))
            let base = (name as NSString).deletingPathExtension
            let file = try ScanRescue.folder().appendingPathComponent("\(base) — AI translation (English).txt")
            try doc.write(to: file, atomically: true, encoding: .utf8)
            let r = try await ingest.ingest(fileAt: file, intent: .fullAvailable)
            await runPostIngestChecksSinceLast()
            return "Added “\(file.lastPathComponent)”: \(r.chunkCount) passage\(r.chunkCount == 1 ? "" : "s"), marked as an AI translation that cites the original."
        } catch is CancellationError {
            return "Stopped. Nothing was added."
        } catch {
            KalsmritikoshLog.app.error("Translate with AI failed: \(error.localizedDescription, privacy: .public)")
            return "Not translated: \(error.localizedDescription)"
        }
    }
}
