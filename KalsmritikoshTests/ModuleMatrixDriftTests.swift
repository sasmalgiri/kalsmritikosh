//
//  ModuleMatrixDriftTests.swift
//  KalsmritikoshTests
//
//  W0-M — MODULE_MATRIX.md is generated from the module specs (ModuleMatrixDocument.render()).
//  This fails when the committed file no longer matches what the code says, so the published
//  matrix can never drift from the switches the app really has. The freshly rendered text is
//  attached as MODULE_MATRIX.md; to regenerate, export the attachment over the repo file.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("W0-M module matrix drift")
struct ModuleMatrixDriftTests {
    @Test func committedMatrixMatchesTheCode() throws {
        let rendered = ModuleMatrixDocument.render()
        Attachment.record(rendered, named: "MODULE_MATRIX.md")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let committed = try String(contentsOf: repo.appendingPathComponent("MODULE_MATRIX.md"), encoding: .utf8)
        #expect(committed == rendered, "MODULE_MATRIX.md is stale — regenerate it from the attached render")
    }
}
