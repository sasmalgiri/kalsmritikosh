//
//  StudioEvidenceResolverTests.swift
//  KalsmritikoshTests
//
//  Final brief §3.2 / §19 "Reference validation": an empty reference, a wrong version or case, an
//  altered quote, an inaccessible source, a detached block and an unassigned draft cannot pass as
//  documentary support; a real passage and a document reference can.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Studio evidence references resolve against the case")
struct StudioEvidenceResolverTests {

    let version = UUID(), otherVersion = UUID(), block = UUID(), object = UUID(), outsideObject = UUID()

    var context: StudioEvidenceContext {
        let block = self.block, version = self.version
        return StudioEvidenceContext(
            eligibleSourceVersions: [version], caseObjects: [object], documentNames: [object: "bank-statement.pdf"],
            blockText: { id in id == block ? (version, "On 5 January 2026 Acme paid ₹1,000 to Vendor LLC.") : nil },
            objectText: { id in id == self.object ? "Acme paid ₹1,000 to Vendor LLC on 5 January." : nil })
    }

    func check(_ value: String, _ ref: StudioEvidenceRef, context: StudioEvidenceContext?) async -> String? {
        await StudioEvidenceResolver.unresolved(values: ["f": value], provenance: ["f": .fromCase(value, [ref])], context: context)["f"]
    }

    @Test("A real passage and a document reference resolve")
    func resolves() async {
        #expect(await check("₹1,000", StudioEvidenceRef(sourceVersionID: version, blockID: block, quote: "Acme paid ₹1,000 to Vendor LLC"), context: context) == nil)
        #expect(await check("bank-statement.pdf", StudioEvidenceRef(objectID: object, quote: "bank-statement.pdf"), context: context) == nil)
        #expect(await check("₹1,000", StudioEvidenceRef(objectID: object, quote: "Acme paid ₹1,000 to Vendor LLC"), context: context) == nil)
    }

    @Test("Empty, wrong-version, altered, inaccessible, detached and unassigned references do not")
    func refuses() async {
        // An empty reference.
        #expect(await check("₹1,000", StudioEvidenceRef(), context: context) != nil)
        // A version outside the case (or not accessible under the export policy).
        #expect(await check("₹1,000", StudioEvidenceRef(sourceVersionID: otherVersion, blockID: block, quote: "Acme paid ₹1,000"), context: context)?.contains("not in this case") == true)
        // A passage of another version.
        let ctx2 = StudioEvidenceContext(eligibleSourceVersions: [version, otherVersion], caseObjects: [], documentNames: [:],
                                         blockText: { _ in (self.version, "Acme paid ₹1,000") }, objectText: { _ in nil })
        #expect(await check("₹1,000", StudioEvidenceRef(sourceVersionID: otherVersion, blockID: block, quote: "Acme paid ₹1,000"), context: ctx2)?.contains("different version") == true)
        // An altered quote.
        #expect(await check("₹1,000", StudioEvidenceRef(sourceVersionID: version, blockID: block, quote: "Acme paid ₹10,000 to Vendor LLC"), context: context)?.contains("not in the cited passage") == true)
        // The quote is real but does not hold the value.
        #expect(await check("₹2,500", StudioEvidenceRef(sourceVersionID: version, blockID: block, quote: "Acme paid ₹1,000 to Vendor LLC"), context: context)?.contains("does not contain this value") == true)
        // A detached (missing) block.
        #expect(await check("₹1,000", StudioEvidenceRef(sourceVersionID: version, blockID: UUID(), quote: "Acme paid ₹1,000"), context: context)?.contains("no longer exists") == true)
        // A document outside the case.
        #expect(await check("x.pdf", StudioEvidenceRef(objectID: outsideObject, quote: "x.pdf"), context: context)?.contains("not in this case") == true)
        // A draft that belongs to no case.
        #expect(await check("₹1,000", StudioEvidenceRef(sourceVersionID: version, blockID: block, quote: "Acme paid ₹1,000"), context: nil) == StudioEvidenceResolver.notAssigned)
    }

    @Test("An edited field is the investigator's entry and is not checked as documentary support")
    func editedField() async {
        let p: StudioProvenance = ["f": .fromCase("₹1,000", [StudioEvidenceRef()])]
        #expect(StudioExportGate.status(of: "₹1,200", provenance: p["f"]) == .investigatorEntry)
        #expect(await StudioEvidenceResolver.unresolved(values: ["f": "₹1,200"], provenance: p, context: nil).isEmpty)
    }
}
