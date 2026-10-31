//
//  KalsmritikoshIntents.swift
//  Kalsmritikosh
//
//  W1-6 — Shortcuts actions: Ask, Ask with a signed receipt, Search, Add files,
//  Open a passage link. They run inside the app against the same ledger, access
//  scope and evidence gate as the Ask screen, and refuse with a clear message
//  when the "Shortcuts actions" module is switched off.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

/// The running app's state, set at launch so intents act on the live ledger.
@MainActor
enum IntentBridge {
    static weak var appState: AppState?

    static func ready() throws -> AppState {
        guard ProductModuleFlags.isEnabled(.shortcutsActions) else { throw KalsmritikoshIntentError.switchedOff }
        guard PurchaseCenter.shared.entitlement.allowsPaidUse else { throw KalsmritikoshIntentError.notPurchased }   // §11 — an intent that creates or analyses is a paid action
        guard let state = appState, state.database != nil else { throw KalsmritikoshIntentError.notReady }
        return state
    }

    /// Ask, exactly as the Ask screen does (same ledger, scope and evidence gate). Shared by the
    /// Shortcuts action and the AppleScript `ask` command.
    static func ask(_ question: String) async throws -> String {
        let state = try ready()
        let answer = await state.brain.answerWithDiagnostics(
            question: question, access: SensitiveAccessContext(scope: .globalOwnerRetrieval())).answer
        return await IntentText.render(answer, state: state)
    }

    /// The best-matching passages, each as "file name: passage". Shared by the Shortcuts action
    /// and the AppleScript `search` command.
    static func search(_ query: String, limit: Int) async throws -> [String] {
        let state = try ready()
        let cap = max(1, min(limit, 100))
        let hits: [Chunk]
        if let advanced = await state.advancedSearch(query, limit: cap) {
            hits = advanced.hits
        } else {
            hits = (try? await state.chunks?.searchFTS(query, limit: cap)) ?? []
        }
        let visible = await state.screenAuthorizer?.filterChunks(hits, boundary: .globalOwner) ?? []
        let names = (try? await state.objects?.sourceFilenames(for: Set(visible.map(\.objectID)))) ?? [:]
        return visible.map { c in "\(names[c.objectID] ?? "Document"): \(c.text.prefix(300))" }
    }
}

enum KalsmritikoshIntentError: Error, CustomLocalizedStringResourceConvertible {
    case switchedOff, notReady, nothingToAdd, notPurchased
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .switchedOff:  return "Shortcuts actions are switched off. Turn on “Shortcuts actions” in Investigations Made Easy ▸ Settings ▸ Modules."
        case .notReady:     return "Investigations Made Easy is still opening its ledger. Try again in a moment."
        case .nothingToAdd: return "No files were given to add."
        case .notPurchased: return "The free trial has ended. Buy Investigations Made Easy once in the app to keep using it."
        }
    }
}

// MARK: - Ask

struct AskKalsmritikoshIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Investigations Made Easy"
    static let description = IntentDescription("Ask a question about your archive. The answer comes only from your documents, with its sources; if the evidence is not there, it says so.")

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary { Summary("Ask Investigations Made Easy \(\.$question)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: try await IntentBridge.ask(question))
    }
}

@available(*, deprecated)
extension AskKalsmritikoshIntent { static var openAppWhenRun: Bool { true } }

// MARK: - Ask with receipt

struct AskWithReceiptIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Investigations Made Easy with a receipt"
    static let description = IntentDescription("Ask a question and get a sealed receipt file listing the answer and every quoted source passage, signed when signed receipts are on.")

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary { Summary("Ask Investigations Made Easy \(\.$question) with a receipt") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let state = try IntentBridge.ready()
        let answer = await state.brain.answerWithDiagnostics(
            question: question, access: SensitiveAccessContext(scope: .globalOwnerRetrieval())).answer
        let names = (try? await state.objects?.sourceFilenames(for: Set(answer.citations.map(\.objectID)))) ?? [:]
        var drafts = [ReceiptDraft(claim: answer.refused ? "No answer: the evidence is not in the archive" : "Answer",
                                   source: "Investigations Made Easy", passage: answer.answerText ?? answer.body)]
        for (i, c) in answer.citations.enumerated() {
            drafts.append(ReceiptDraft(claim: "Supporting evidence \(i + 1)",
                                       source: names[c.objectID] ?? c.objectID.uuidString, passage: c.snippet))
        }
        let sealed = VerifiableReceipt.seal(title: "Answer: \(question)", drafts: drafts)
        let data = Data(ReceiptSigner.exportJSON(sealed).utf8)
        return .result(value: IntentFile(data: data, filename: "receipt.json", type: .json))
    }
}

@available(*, deprecated)
extension AskWithReceiptIntent { static var openAppWhenRun: Bool { true } }

// MARK: - Search

struct SearchKalsmritikoshIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Investigations Made Easy"
    static let description = IntentDescription("Search your archive and get the best-matching passages with their file names. Advanced syntax works when it is switched on.")

    @Parameter(title: "Search")
    var query: String

    @Parameter(title: "Maximum results", default: 10)
    var limit: Int

    static var parameterSummary: some ParameterSummary { Summary("Search Investigations Made Easy for \(\.$query)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        return .result(value: try await IntentBridge.search(query, limit: limit))
    }
}

@available(*, deprecated)
extension SearchKalsmritikoshIntent { static var openAppWhenRun: Bool { true } }

// MARK: - Add files

struct AddFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Add files to Investigations Made Easy"
    static let description = IntentDescription("Add files to your archive. They are read on this Mac and an import receipt is written when receipts are on.")

    @Parameter(title: "Files", supportedContentTypes: [.item])
    var files: [IntentFile]

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let state = try IntentBridge.ready()
        let urls = files.compactMap(\.fileURL)
        guard !urls.isEmpty else { throw KalsmritikoshIntentError.nothingToAdd }
        await state.ingestFiles(urls)
        return .result(value: urls.count)
    }
}

@available(*, deprecated)
extension AddFilesIntent { static var openAppWhenRun: Bool { true } }

// MARK: - Open a passage link

struct OpenPassageLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open an Investigations Made Easy link"
    static let description = IntentDescription("Open a kalsmritikosh:// link at its passage.")

    @Parameter(title: "Link")
    var link: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try IntentBridge.ready()
        await state.handleDeepLink(link)
        return .result()
    }
}

@available(*, deprecated)
extension OpenPassageLinkIntent { static var openAppWhenRun: Bool { true } }

// MARK: - Shortcuts surface

struct KalsmritikoshShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskKalsmritikoshIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask", systemImageName: "questionmark.bubble")
        AppShortcut(intent: SearchKalsmritikoshIntent(),
                    phrases: ["Search \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
    }
}

// MARK: - Text rendering

@MainActor
enum IntentText {
    static func render(_ answer: VerifiedAnswer, state: AppState) async -> String {
        if answer.refused {
            return answer.refusalReason ?? "Your archive does not contain evidence for that."
        }
        let names = (try? await state.objects?.sourceFilenames(for: Set(answer.citations.map(\.objectID)))) ?? [:]
        var seen = Set<UUID>()
        let sources = answer.citations.compactMap { c -> String? in
            guard seen.insert(c.objectID).inserted else { return nil }
            return names[c.objectID]
        }
        var text = answer.answerText ?? answer.body
        if !sources.isEmpty { text += "\n\nSources: " + sources.joined(separator: "; ") }
        return text
    }
}
