//
//  UniversalParserRegistryTests.swift
//  KalsmritikoshTests
//
//  USF-M1 (USF-003) — the one immutable production parser registry: builds cleanly, owns exactly
//  one plugin per SourceType, resolves media as deferred / archives as container / unknown via the
//  explicit fallback, and rejects duplicate IDs, duplicate type ownership, blank identity and
//  loader/structural type mismatches. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M1 — universal parser registry")
@MainActor
struct UniversalParserRegistryTests {

    private func standard() throws -> UniversalParserRegistry {
        try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
    }

    private func adapter(_ id: String, _ types: Set<SourceType>) -> ExistingParserPluginAdapter {
        ExistingParserPluginAdapter(pluginID: id, pluginVersion: "1", supportedTypes: types,
                                    executionMode: .immediate, loader: TextLoader(),
                                    enforceLoaderTypeSupport: false, declaredSurfaces: [.text])
    }
    private func fallback() -> ExistingParserPluginAdapter { adapter("system.generic-text-fallback", [.unknown]) }

    @Test("The standard registry builds and owns every source type exactly once")
    func standardBuildsAndCoversEveryType() throws {
        let registry = try standard()
        for t in SourceType.allCases { #expect(registry.owns(t), "no plugin owns \(t.rawValue)") }
    }

    @Test("Resolution routes each category to the right execution mode")
    func resolutionModes() throws {
        let registry = try standard()
        #expect(try registry.resolve(.txt).executionMode == .immediate)
        #expect(try registry.resolve(.pdf).executionMode == .immediate)
        #expect(try registry.resolve(.mp3).executionMode == .deferred)
        #expect(try registry.resolve(.mp4).executionMode == .deferred)
        #expect(try registry.resolve(.zip).executionMode == .container)
        #expect(try registry.resolve(.unknown).pluginID == "system.generic-text-fallback")
    }

    @Test("A structural-owning type declares structure capability; media does not")
    func capabilityDeclarations() throws {
        let registry = try standard()
        #expect(try registry.resolve(.txt).capabilities.producesStructure)
        #expect(try registry.resolve(.pdf).capabilities.requiresOCR)
        #expect(try registry.resolve(.mp3).capabilities.producesStructure == false)
    }

    @Test("Media is deferred and wraps no loader while transcription is off")
    func mediaIsPreservedOnlyDeferred() throws {
        let registry = try standard()
        #expect(try registry.resolve(.mp3) is PreservedOnlyPlugin)
        #expect(try registry.resolve(.mov) is PreservedOnlyPlugin)
    }

    @Test("Enabling transcription gives audio AND video a real immediate ASR plugin")
    func mediaTranscriptionActivatesLoaders() throws {
        let on = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR(), mediaTranscriptionEnabled: true)
        // Every audio and video type the app recognizes must be owned by a real
        // plugin — not a subset. A half-wired media lane is how a recording
        // silently stays mute.
        for t in SourceType.allCases where t.category == .audio || t.category == .video {
            let plugin = try on.resolve(t)
            #expect(plugin is ExistingParserPluginAdapter, "\(t.rawValue) still preserved-only with transcription on")
            #expect(plugin.executionMode == .immediate, "\(t.rawValue) not immediate with transcription on")
            #expect(plugin.capabilities.declaredSurfaces.contains(.text), "\(t.rawValue) claims no text surface with transcription on")
        }
        // And the flag is genuinely a gate, not decoration.
        #expect(try standard().resolve(.mp3) is PreservedOnlyPlugin)
    }

    @Test("Advertised media coverage follows the transcription switch (DEFERRED → PARTIAL)")
    func mediaCoverageIsHonest() throws {
        func coverage(_ reg: UniversalParserRegistry, _ t: SourceType) -> ParserCoverage? {
            ParserCapabilityManifest.generate(registry: reg).first { $0.sourceType == t.rawValue }?.coverage
        }
        let off = try standard()
        #expect(coverage(off, .mp3) == .deferred)
        #expect(coverage(off, .mov) == .deferred)
        let on = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR(), mediaTranscriptionEnabled: true)
        // PARTIAL, never FULL — ASR text without document structure.
        #expect(coverage(on, .mp3) == .partial)
        #expect(coverage(on, .mov) == .partial)
    }

    @Test("Feature-gated parsers are absent unless enabled")
    func featureGatedAbsentByDefault() throws {
        let off = try standard()
        #expect(!(try off.resolve(.imessage) is ExistingParserPluginAdapter))   // preserved-only when off
        let on = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR(), iMessageEnabled: true, browserHistoryEnabled: true, chatExportEnabled: true)
        #expect(try on.resolve(.imessage) is ExistingParserPluginAdapter)
        #expect(try on.resolve(.safariHistory) is ExistingParserPluginAdapter)
    }

    @Test("A duplicate plugin id is rejected")
    func duplicatePluginID() {
        #expect(throws: UniversalParserError.self) {
            _ = try UniversalParserRegistry(plugins: [self.adapter("dup", [.txt]), self.adapter("dup", [.markdown])], unknownFallback: self.fallback())
        }
    }

    @Test("Duplicate source-type ownership is rejected (no last-wins)")
    func duplicateTypeOwnerRejected() {
        #expect(throws: UniversalParserError.self) {
            _ = try UniversalParserRegistry(plugins: [self.adapter("a", [.txt]), self.adapter("b", [.txt])], unknownFallback: self.fallback())
        }
    }

    @Test("A blank plugin id is rejected")
    func blankPluginIDRejected() {
        #expect(throws: UniversalParserError.self) {
            _ = try UniversalParserRegistry(plugins: [self.adapter("", [.txt])], unknownFallback: self.fallback())
        }
    }

    @Test("Empty supported types are rejected")
    func emptySupportedTypesRejected() {
        #expect(throws: UniversalParserError.self) {
            _ = try UniversalParserRegistry(plugins: [self.adapter("empty", [])], unknownFallback: self.fallback())
        }
    }

    @Test("A loader that does not advertise a declared type is rejected")
    func loaderTypeMismatchRejected() {
        // TextLoader supports [txt, markdown, rtf]; declaring .pdf with enforcement on must fail.
        let bad = ExistingParserPluginAdapter(pluginID: "bad", pluginVersion: "1", supportedTypes: [.pdf],
                                              executionMode: .immediate, loader: TextLoader(), declaredSurfaces: [.text])
        #expect(throws: UniversalParserError.self) {
            _ = try UniversalParserRegistry(plugins: [bad], unknownFallback: self.fallback())
        }
    }

    @Test("An unknown fallback that does not own .unknown is rejected")
    func fallbackMustOwnUnknown() {
        #expect(throws: UniversalParserError.self) {
            _ = try UniversalParserRegistry(plugins: [self.adapter("a", [.txt])], unknownFallback: self.adapter("f", [.markdown]))
        }
    }

    @Test("Resolving an unowned type in a partial registry throws pluginNotFound")
    func resolveUnownedThrows() throws {
        let registry = try UniversalParserRegistry(plugins: [adapter("a", [.txt])], unknownFallback: fallback())
        #expect(throws: UniversalParserError.self) { _ = try registry.resolve(.pdf) }
    }

    @Test("A structural parser that does not support a declared type is rejected")
    func structuralTypeMismatchRejected() {
        // PlainTextStructuralParser supports text kinds, not .pdf; force a mismatch.
        let bad = ExistingParserPluginAdapter(pluginID: "bad2", pluginVersion: "1", supportedTypes: [.pdf],
                                              executionMode: .immediate, loader: PDFLoader(ocr: VisionOCR()),
                                              structural: PlainTextStructuralParser(), declaredSurfaces: [.text])
        #expect(throws: UniversalParserError.self) {
            _ = try UniversalParserRegistry(plugins: [bad], unknownFallback: self.fallback())
        }
    }

    @Test("The capability manifest derives its coverage from the ONE registry")
    func manifestDerivesFromRegistry() throws {
        let registry = try standard()
        let entries = ParserCapabilityManifest.generate(registry: registry)
        // One entry per known type, each tied to its owning plugin's declared execution mode.
        #expect(entries.contains { $0.sourceType == "txt" && $0.coverage == .full && $0.pluginID == "format.txt" })
        #expect(entries.contains { $0.sourceType == "pdf" && $0.coverage == .partial })            // OCR-dependent
        #expect(entries.contains { $0.sourceType == "mp3" && $0.coverage == .deferred })
        #expect(entries.contains { $0.sourceType == "zip" && $0.coverage == .preservedOnly })       // container mode
        #expect(!ParserCapabilityManifest.renderMarkdown(registry: registry).isEmpty)
    }
}
