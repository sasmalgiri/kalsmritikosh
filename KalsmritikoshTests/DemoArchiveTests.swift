//
//  DemoArchiveTests.swift
//  KalsmritikoshTests
//
//  RC physical proof (2026-08-28) — the synchronized resource folder FLATTENS
//  Resources/Fixtures/ProjectDelta into Contents/Resources, which made the
//  old directory lookup return nil: the onboarding "Try the demo archive"
//  button (App Review's documented first step) silently vanished from the
//  archived app. DemoArchive must resolve the corpus as a REAL folder with
//  the complete 8-file set in both bundle layouts.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Demo archive resolution (RC physical proof)")
struct DemoArchiveTests {

    @Test("DemoArchive.url() yields a real ProjectDelta folder with the complete fixture set")
    func demoArchiveResolves() throws {
        // The host app carries the fixtures (flattened or as a folder). If a
        // stripped host ever runs this suite, the fixture set is absent and
        // nil is the CORRECT fail-closed answer — assert that consistency.
        let bundled = DemoArchive.fixtureNames.allSatisfy {
            Bundle.main.url(forResource: $0, withExtension: nil) != nil
        } || Bundle.main.url(forResource: "ProjectDelta", withExtension: nil,
                             subdirectory: "Fixtures") != nil
        guard bundled else {
            #expect(DemoArchive.url() == nil, "no fixtures in this host ⇒ fail-closed nil")
            return
        }
        let url = try #require(DemoArchive.url(), "fixtures are bundled — the demo must resolve")
        #expect(url.lastPathComponent == "ProjectDelta")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
        #expect(names.isSuperset(of: Set(DemoArchive.fixtureNames)),
                "demo folder must carry the complete 8-file corpus, got: \(names.sorted())")
    }
}
