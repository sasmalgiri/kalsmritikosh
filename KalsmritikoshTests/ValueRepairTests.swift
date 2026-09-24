//
//  ValueRepairTests.swift
//  KalsmritikoshTests
//
//  C-4 cross-block assembly + OCR digit recovery — the two REPAIR producers.
//
//  Both recover a value the strict reader cannot see, so both can INVENT one.
//  That asymmetry decides how this suite is weighted: the happy paths are two
//  tests, and everything else pins what must be REFUSED. A missing identifier
//  is a gap the examiner can see and work around; a confidently wrong one gets
//  cited.
//
//  The single most valuable case here is `proseEndingInTheWordNumberIsNotALabel`
//  — the archive's own noise fixture ends a sentence with "…about the patent
//  number.", and a naive cross-block rule would mint the following block's
//  first number as the patent number.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Value repair: cross-block assembly and OCR digit recovery")
struct ValueRepairTests {

    private let gen = NoiseFixtureGenerator()

    /// `GenericFact.init` normalizes every field through
    /// `FactSchemaRegistry`, which LOWERCASES it — a stored fact's field is
    /// "patentnumber", never the "patentNumber" the pack passes in. Comparing
    /// against the camel-cased spelling silently matches nothing.
    private nonisolated static let patentNumberField =
        FactSchemaRegistry.normalizeField("patentNumber")

    private func block(_ text: String) -> CrossBlockLabelAssembler.Block {
        .init(id: UUID(), text: text)
    }

    // MARK: - OCR recovery: what it repairs

    /// What the noise generator's scan of "700321" actually looks like. It
    /// applies 0→O AND 1→l, so THREE of the six characters are letters — half
    /// the token. Pinned here because that ratio is what sets
    /// `OCRDigitRecovery.maximumSubstitutionRatio`: a tighter bound refuses the
    /// very fixture this producer exists for.
    private nonisolated static let scannedPatentNumber = "7OO32l"

    @Test("A scanned patent number with letter-for-digit misreads is recovered")
    func ocrDigitsAreRestored() throws {
        // The generator's own substitution set: 0→O, 1→l, 5→S.
        #expect(OCRDigitRecovery.recover(Self.scannedPatentNumber) == "700321")
        #expect(OCRDigitRecovery.recover("7OO321") == "700321")
        #expect(OCRDigitRecovery.recover("20239801234S") == "202398012345")
        #expect(OCRDigitRecovery.recover("l23456") == "123456")
    }

    @Test("The fixture's scanned form is exactly what the generator produces")
    func scannedFormMatchesTheGenerator() throws {
        // If the generator's substitution set changes, this fails loudly rather
        // than letting the recovery suite drift away from the fixture it is
        // meant to cover.
        #expect(gen.ocrGrantLetter.contains(Self.scannedPatentNumber),
                "the OCR fixture no longer contains \(Self.scannedPatentNumber)")
        #expect(!gen.ocrGrantLetter.contains(gen.patentNumber),
                "the OCR fixture states the clean number too, so nothing needs recovering")
    }

    @Test("The OCR-recovered value reaches the ledger as a flagged patent number")
    func ocrRecoveredFactIsProducedAndFlagged() throws {
        let facts = PatentDomainPack.extractFacts(
            fromText: gen.ocrGrantLetter, subjectLabel: "scan", blockID: UUID())
        let patent = try #require(facts.first { $0.field == Self.patentNumberField },
                                  "the scanned letter produced no patentNumber fact")
        #expect(patent.value == "700321")
        // The mark and the receipt are the point: a reader must be able to tell
        // this from a value the page states plainly.
        #expect(patent.derivation == .ocrCorrected)
        #expect(patent.confidence < 0.8, "a repaired reading must sit below the verbatim tier")
        let receipt = try #require(patent.rawMatch)
        #expect(receipt.contains(Self.scannedPatentNumber),
                "the receipt must keep the SCANNED form, got \(receipt)")
    }

    // MARK: - OCR recovery: what it must refuse

    @Test("Ordinary words are never minted into identifiers")
    func wordsAreNotTurnedIntoNumbers() throws {
        // Every one of these is all-confusable-letters. Substituting blindly
        // would produce a plausible-looking identifier out of a word: the
        // failure mode that makes this producer dangerous.
        for word in ["SOLO", "BOSS", "GIGS", "OSLO", "ZOO", "IGLOO", "BOGGLES", "SISSOO"] {
            #expect(OCRDigitRecovery.recover(word) == nil,
                    "\"\(word)\" was minted into \(OCRDigitRecovery.recover(word) ?? "")")
        }
    }

    @Test("A clean number is not claimed as a repair")
    func cleanNumbersAreNotMarkedRepaired() throws {
        // Nothing was substituted, so this is the strict reader's value. If
        // recovery claimed it, every clean fact on a scanned page would be
        // flagged as repaired.
        #expect(OCRDigitRecovery.recover("700321") == nil)
        let facts = PatentDomainPack.extractFacts(
            fromText: "Patent No. 700321", subjectLabel: "letter", blockID: UUID())
        let patent = try #require(facts.first { $0.field == Self.patentNumberField })
        #expect(patent.value == "700321")
        #expect(patent.derivation == nil, "a verbatim value must carry NO derivation mark")
        #expect(patent.confidence == 0.8)
    }

    @Test("A value read cleanly anywhere wins over a repaired reading of it")
    func verbatimBeatsRepairedOnMerge() throws {
        // The same number appears mangled and clean in one block. The ledger
        // must hold ONE fact, unflagged: the clean line corroborates it, and
        // marking it repaired would understate the evidence actually held.
        let facts = PatentDomainPack.extractFacts(
            fromText: "Patent No. 7OO321\nPatent No. 700321",
            subjectLabel: "letter", blockID: UUID())
        let patents = DomainFactExtractor.merge(facts).filter { $0.field == Self.patentNumberField }
        #expect(patents.count == 1, "expected one merged fact, got \(patents.map(\.value))")
        let patent = try #require(patents.first)
        #expect(patent.value == "700321")
        #expect(patent.derivation == nil, "the clean reading must win the merge")
    }

    @Test("Too little of the number surviving is a refusal, not a guess")
    func mostlyLettersIsRefused() throws {
        // Two digits out of eight: whatever this was, restoring it is invention.
        #expect(OCRDigitRecovery.recover("SOlOZBG1") == nil)
        // Below identifier length.
        #expect(OCRDigitRecovery.recover("7O3") == nil)
        // A letter that is NOT a known confusion leaves the token alone
        // entirely — a partial repair would match no real identifier.
        #expect(OCRDigitRecovery.recover("7OO32X") == nil)
    }

    @Test("The recovery table and its regex character class cannot drift apart")
    func confusionTableAndPatternAgree() throws {
        // The pattern decides what is ASKED about; the table decides what can
        // be repaired. A letter in one but not the other is a silent dead end.
        let characterClass = OCRDigitRecovery.candidateCharacterClass
        for letter in OCRDigitRecovery.confusions.keys {
            #expect(characterClass.contains(letter),
                    "\(letter) is repairable but the pattern never matches it")
        }
        for character in characterClass where character.isLetter {
            #expect(OCRDigitRecovery.confusions[character] != nil,
                    "the pattern matches \(character) but it can never be repaired")
        }
    }

    // MARK: - Cross-block assembly: what it repairs

    @Test("A label at the foot of a page finds its value at the head of the next")
    func pageBreakIsRejoined() throws {
        let blocks = [
            block("# Intellectual Property Office — Letter of Grant"),
            block("In the matter of the application for patent filed by Nila Instruments Pvt Ltd,\nthe following particulars are recorded. Patent No."),
            block("--- PAGE 2 ---"),
            block("700321\nDate of Grant : 17 June 2025")
        ]
        let assemblies = CrossBlockLabelAssembler().assemblies(in: blocks)
        let assembly = try #require(assemblies.first, "the page break was not rejoined")
        #expect(assembly.value == "700321")
        #expect(assembly.text == "Patent No. 700321")
        // BOTH halves are cited, because neither supports the claim alone.
        #expect(assembly.blockIDs.count == 2)
        #expect(assembly.blockIDs.contains(blocks[1].id))
        #expect(assembly.blockIDs.contains(blocks[3].id))
    }

    @Test("The same break INSIDE one block is rejoined by the same rule")
    func intraBlockPageBreakIsRejoined() throws {
        // A plain-text parse puts the whole page in one block, so the halves sit
        // either side of a page-break LINE rather than in different blocks.
        let single = block("the following particulars are recorded. Patent No.\n\n--- PAGE 2 ---\n\n700321\nDate of Grant : 17 June 2025")
        let assembly = try #require(CrossBlockLabelAssembler().assemblies(in: [single]).first)
        #expect(assembly.value == "700321")
        #expect(assembly.blockIDs == [single.id], "one block contributed, so one is cited")
    }

    @Test("The rejoined value becomes a flagged fact citing both blocks")
    func assembledFactIsProducedAndFlagged() throws {
        let label = block("the following particulars are recorded. Patent No.")
        let value = block("700321\nDate of Grant : 17 June 2025")
        let facts = DomainFactExtractor().extract(
            fromBlocks: [label, block("--- PAGE 2 ---"), value], subjectLabel: "split")
        let patent = try #require(facts.first { $0.field == Self.patentNumberField },
                                  "no patentNumber fact from the split letter")
        #expect(patent.value == "700321")
        #expect(patent.derivation == .crossBlockAssembled)
        #expect(patent.confidence < 0.8)
        #expect(Set(patent.sourceBlockIDs) == Set([label.id, value.id]),
                "the receipt must land on both halves")
    }

    @Test("Assembly only produces identifier facts, never dates or statuses")
    func assemblyIsRestrictedToIdentifiers() throws {
        // The joined string is a two-token synthetic built to let a label reach
        // its number. Anything else it happens to produce is not something a
        // block actually states in that form.
        let facts = DomainFactExtractor.crossBlockFacts(
            in: [block("Particulars are recorded. Patent No."), block("700321 granted")],
            subjectLabel: "s", documentClass: nil)
        #expect(!facts.isEmpty)
        for fact in facts {
            #expect(FactSchemaRegistry.expectedShape(of: fact.field) == .identifier,
                    "assembly produced a non-identifier field: \(fact.field)=\(fact.value)")
        }
    }

    // MARK: - Cross-block assembly: what it must refuse

    @Test("Prose ending in the word \"number\" is not a dangling label")
    func proseEndingInTheWordNumberIsNotALabel() throws {
        // THE case this producer exists to get right. The archive's own noise
        // fixture ends a sentence this way, and the very next block opens with
        // a number that is NOT the patent number.
        #expect(CrossBlockLabelAssembler.danglingLabel(
            endingIn: "Refer to the patent number in all correspondence about the patent number.") == nil)
        let assemblies = CrossBlockLabelAssembler().assemblies(in: [
            block("The patent number appears on the certificate. Refer to the patent number."),
            block("202398012345 is the application number.")
        ])
        #expect(assemblies.isEmpty,
                "prose was read as a label and minted \(assemblies.map(\.value))")
    }

    @Test("A label qualifies when it opens a line or follows a sentence end")
    func labelPositionGate() throws {
        #expect(CrossBlockLabelAssembler.danglingLabel(endingIn: "Particulars follow.\nPatent No.") != nil)
        #expect(CrossBlockLabelAssembler.danglingLabel(endingIn: "…are recorded. Patent No.") != nil)
        #expect(CrossBlockLabelAssembler.danglingLabel(endingIn: "Patent No.") != nil)
        // Mid-clause: prose, not a field.
        #expect(CrossBlockLabelAssembler.danglingLabel(endingIn: "please quote the patent no.") == nil)
        // The bare word is never a label — it is how ordinary sentences end.
        #expect(CrossBlockLabelAssembler.danglingLabel(endingIn: "an application for a patent") == nil)
        #expect(CrossBlockLabelAssembler.danglingLabel(endingIn: "the granted patent") == nil)
    }

    @Test("A date after a dangling label is refused, not stored as an identifier")
    func dateFollowingALabelIsNotAValue() throws {
        #expect(CrossBlockLabelAssembler.leadingValueToken(of: "22/03/2023\nsomething") == nil)
        #expect(CrossBlockLabelAssembler.leadingValueToken(of: "2023-03-22") == nil)
        let assemblies = CrossBlockLabelAssembler().assemblies(in: [
            block("Particulars are recorded. Patent No."),
            block("22/03/2023")
        ])
        #expect(assemblies.isEmpty, "a slash date was assembled as an identifier")
    }

    @Test("A next block opening with prose yields no assembly")
    func proseValueIsRefused() throws {
        let assemblies = CrossBlockLabelAssembler().assemblies(in: [
            block("Particulars are recorded. Patent No."),
            block("will be communicated separately once the Office has issued it.")
        ])
        #expect(assemblies.isEmpty)
    }

    @Test("The value must be at the START of the next block")
    func valueMustLeadTheNextBlock() throws {
        // A number further in belongs to its own line and has its own label;
        // reaching for it would let a dangling label capture anything on the
        // following page.
        let assemblies = CrossBlockLabelAssembler().assemblies(in: [
            block("Particulars are recorded. Patent No."),
            block("The Office confirms that Patent No. 700321 was granted.")
        ])
        #expect(assemblies.isEmpty)
    }

    @Test("The search does not wander far past the break")
    func lookaheadIsBounded() throws {
        let assemblies = CrossBlockLabelAssembler().assemblies(in: [
            block("Particulars are recorded. Patent No."),
            block("Some intervening paragraph of content that is not the value."),
            block("Another intervening paragraph, also not the value."),
            block("700321")
        ])
        #expect(assemblies.isEmpty, "the value was taken from too far down the document")
    }

    @Test("Page furniture is recognized, and a bare value line is NOT furniture")
    func pageFurnitureClassification() throws {
        for furniture in ["--- PAGE 2 ---", "Page 3 of 9", "[Page 4]", "- 12 -", "page 7", "\u{000C}"] {
            #expect(CrossBlockLabelAssembler.isPageFurniture(furniture),
                    "\"\(furniture)\" was not recognized as page furniture")
        }
        // The line that CARRIES the value must never be eaten as a folio.
        for content in ["700321", "202398012345", "Patent No. 700321", "Date of Grant : 17 June 2025"] {
            #expect(!CrossBlockLabelAssembler.isPageFurniture(content),
                    "\"\(content)\" was discarded as page furniture")
        }
    }

    // MARK: - The noisy fixture must not regress

    @Test("The multi-spelling noisy letter still yields exactly one patent number")
    func noisyLetterIsUnaffected() throws {
        // This fixture has six label spellings, a mislabel, decoy label density
        // and a slash date in identifier position. The repair producers must add
        // NOTHING to it: every value in it is stated plainly somewhere.
        let facts = DomainFactExtractor().extract(
            fromBlocks: gen.noisyGrantLetter
                .components(separatedBy: "\n\n")
                .map { block($0) },
            subjectLabel: "noisy")
        let patents = facts.filter { $0.field == Self.patentNumberField }
        #expect(patents.count == 1, "expected one patent number, got \(patents.map(\.value))")
        #expect(patents.first?.value == "700321")
        // Nothing in this document needed repairing.
        for fact in facts {
            #expect(fact.derivation == nil,
                    "\(fact.field)=\(fact.value) was marked \(fact.derivation!.rawValue) in a clean document")
        }
    }

    // MARK: - Cost (both producers run on EVERY block of EVERY document)

    @Test("The repair passes add negligible cost to a large, label-dense document",
          .timeLimit(.minutes(1)))
    func repairPassesAreCheap() throws {
        // Worst case for both: the label word thousands of times, a trailing
        // prose "patent number." on every paragraph for the positional gate to
        // reject, and a real value to find. Measured at ~0.3s for 450 KB when
        // this landed; the bound is loose enough not to be flaky on a busy
        // machine and tight enough to catch an accidental quadratic.
        let para = """
        In the matter of the application for patent filed by Nila Instruments Pvt Ltd,
        the patent is hereby granted. Refer to the patent number in all correspondence
        about the patent number. Patent No. 700321 was allotted upon grant.
        """
        let blocks = (0..<2000).map { _ in block(para) }

        let startedAssembly = Date()
        _ = CrossBlockLabelAssembler().assemblies(in: blocks)
        let assemblyElapsed = Date().timeIntervalSince(startedAssembly)
        #expect(assemblyElapsed < 5.0, "cross-block scan of 450 KB took \(assemblyElapsed)s")

        let startedOCR = Date()
        for b in blocks {
            _ = PatentDomainPack.captureGroups(PatentDomainPack.ocrNumberCapturePattern, in: b.text)
        }
        let ocrElapsed = Date().timeIntervalSince(startedOCR)
        #expect(ocrElapsed < 5.0, "OCR pattern over 450 KB took \(ocrElapsed)s")
    }

    // MARK: - Durability of the mark

    @Test("The derivation mark survives a round trip through the ledger")
    func derivationRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("derivation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try await Database(url: url)
        try await SchemaMigrations.migrate(db)
        let repo = GenericFactRepository(database: db)

        let blockID = UUID()
        let repaired = GenericFact(
            subjectLabel: "scan", field: "patentNumber", value: "700321",
            status: .sourceAsserted, confidence: 0.55, sourceBlockIDs: [blockID],
            producerVersion: DerivedProducerVersions.facts, rawMatch: "Patent No. 7OO321",
            sourceCount: 1, derivation: .ocrCorrected)
        try await repo.upsert(repaired)

        let read = try await repo.facts(subjectLabel: "scan", field: "patentNumber")
        #expect(read.count == 1)
        #expect(read.first?.derivation == .ocrCorrected)
        #expect(read.first?.rawMatch == "Patent No. 7OO321")
    }

    @Test("A stored verbatim row is not re-flagged by a later repaired occurrence")
    func storedVerbatimSurvivesMergeUpsert() async throws {
        // THE trap in the write path: `mergeUpsert` builds its canonical seed
        // mostly from the INCOMING fact, so seeding the derivation from there
        // would let a repaired occurrence overwrite an already-clean row. The
        // stored NULL asserts "some block states this exactly" and must hold.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbatim-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try await Database(url: url)
        try await SchemaMigrations.migrate(db)
        let repo = GenericFactRepository(database: db)

        func fact(_ derivation: FactDerivation?, _ confidence: Double) -> GenericFact {
            GenericFact(subjectLabel: "letter", field: "patentNumber", value: "700321",
                        status: .sourceAsserted, confidence: confidence,
                        sourceBlockIDs: [UUID()],
                        producerVersion: DerivedProducerVersions.facts,
                        sourceCount: 1, derivation: derivation)
        }
        try await repo.mergeUpsert(fact(nil, 0.8))              // read cleanly
        try await repo.mergeUpsert(fact(.ocrCorrected, 0.55))   // and again, mangled

        let read = try await repo.facts(subjectLabel: "letter", field: "patentNumber")
        #expect(read.count == 1, "the merge minted a duplicate row")
        #expect(read.first?.derivation == nil,
                "a clean row was re-flagged as repaired by a later scan")
    }
}
