//
//  ParserCapabilityMatrixTests.swift
//  KalsmritikoshTests
//
//  PAR-010 — the advertised-format matrix is generated from code and must be complete
//  and honest: every SourceType is classified exactly once, and every FULL/PARTIAL format
//  is actually backed by a registered structural parser (no over-advertising).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Parser capability matrix (PAR-010)")
struct ParserCapabilityMatrixTests {

    private let registry = StructuralParserRegistry.standard

    @Test("Every source type (except unknown) is classified exactly once")
    func complete() {
        let entries = ParserCapabilityManifest.generate(registry: registry)
        let advertised = Set(SourceType.allCases.filter { $0 != .unknown }.map(\.rawValue))
        let classified = Set(entries.map(\.sourceType))
        #expect(classified == advertised)
        #expect(entries.count == advertised.count)   // exactly once each
    }

    @Test("Every FULL/PARTIAL format is backed by a registered parser")
    func fullFormatsHaveParsers() {
        for entry in ParserCapabilityManifest.generate(registry: registry)
        where entry.coverage == .full || entry.coverage == .partial {
            let type = try! #require(SourceType(rawValue: entry.sourceType))
            #expect(registry.parser(for: type) != nil,
                    "Advertised \(entry.coverage.rawValue) format \(entry.sourceType) has no parser")
            #expect(entry.parserName != nil)
        }
    }

    @Test("PRESERVED-ONLY / DEFERRED formats have no parser")
    func uncoveredHaveNoParser() {
        for entry in ParserCapabilityManifest.generate(registry: registry)
        where entry.coverage == .preservedOnly || entry.coverage == .deferred {
            let type = try! #require(SourceType(rawValue: entry.sourceType))
            #expect(registry.parser(for: type) == nil)
        }
    }

    @Test("The new PAR-008/009 formats are advertised FULL")
    func newFormatsFull() {
        let byType = Dictionary(
            uniqueKeysWithValues: ParserCapabilityManifest.generate(registry: registry)
                .map { ($0.sourceType, $0.coverage) })
        for t in ["html", "json", "xml", "log", "sqlite"] {
            #expect(byType[t] == .full, "\(t) should be FULL")
        }
    }

    @Test("Media formats are DEFERRED, never FULL")
    func mediaDeferred() {
        for entry in ParserCapabilityManifest.generate(registry: registry) {
            let type = SourceType(rawValue: entry.sourceType)!
            if type.category == .audio || type.category == .video {
                #expect(entry.coverage == .deferred)
            }
        }
    }
}
