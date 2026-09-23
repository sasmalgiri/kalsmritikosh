//
//  CustodyManifestStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-8 — puts the chain of custody INTO the ledger as citable evidence, so
//  "who acquired this, when, and under what authority" is an answerable question
//  with a source, exactly like any other fact in the archive. No schema change
//  is needed for that: custody facts are evidence blocks like everything else.
//
//  One field per block, deliberately. A single summary paragraph would let a
//  retrieved answer quote "acquired by Insp. R. Ahmed" while silently dropping
//  "under Search warrant 412/2026" — and in a proceeding the authority is the
//  part that matters. Separate blocks mean each fact is cited on its own.
//
//  The completeness of the chain is emitted too. An incomplete chain is still
//  evidence; it simply must never be presented as a complete one.
//

import Foundation
import CryptoKit

public struct CustodyManifestStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.custodyManifest] }
    public nonisolated var parserName: String { "chain-of-custody" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, field: String,
                 extra: [String: AnyCodable] = [:]) {
            var attributes = extra
            attributes["custodyField"] = AnyCodable(.string(field))
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: ["Chain of custody", field]),
                attributes: attributes))
        }
        func document(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .custodyManifest,
                mimeType: "application/vnd.kalsmritikosh.custody+json",
                contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "custody.empty",
                                          message: "Custody manifest is zero bytes."))
            return document(.empty)
        }
        guard let record = CustodyRecord.decode(data) else {
            // "No custody file" and "unreadable custody file" are different facts,
            // and the second one must be loud: it means someone intended to
            // document the chain and the documentation cannot be read.
            warnings.append(ParserWarning(severity: .error, code: "custody.undecodable",
                message: "Custody manifest is not a readable JSON object. The chain of "
                       + "custody for this evidence is therefore NOT recorded."))
            return document(.corrupt)
        }

        // The header is the disclosure line an answer can carry as a footer.
        add(.documentHeader, record.disclosure, field: "summary", extra: [
            "isComplete": AnyCodable(.bool(record.isComplete)),
            "isDocumented": AnyCodable(.bool(record.isDocumented)),
            "missingFieldCount": AnyCodable(.int(Int64(record.missingFields.count)))
        ])

        // One fact, one block, one citation.
        func fact(_ label: String, _ value: String?, field: String) {
            guard let value else { return }
            add(.paragraph, "\(label): \(value)", field: field)
        }
        fact("Case number", record.caseNumber, field: "caseNumber")
        fact("Evidence number", record.evidenceNumber, field: "evidenceNumber")
        fact("Examiner", record.examiner, field: "examiner")
        fact("Agency", record.agency, field: "agency")
        fact("Legal authority", record.authority, field: "authority")
        fact("Acquisition tool", record.acquisitionTool, field: "acquisitionTool")
        if let date = record.acquisitionDate {
            add(.paragraph, "Acquired: \(CustodyRecord.iso8601.string(from: date))",
                field: "acquisitionDate",
                extra: ["timestamp": AnyCodable(.string(CustodyRecord.iso8601.string(from: date)))])
        }
        fact("Source device", record.sourceDevice, field: "sourceDevice")
        fact("Source device identifier", record.sourceDeviceIdentifier,
             field: "sourceDeviceIdentifier")
        fact("Source device time zone", record.sourceTimeZone, field: "sourceTimeZone")
        if let imageHash = record.imageHash {
            add(.paragraph, "Image hash (\(imageHash.algorithm)): \(imageHash.value)",
                field: "imageHash", extra: [
                    "hashAlgorithm": AnyCodable(.string(imageHash.algorithm)),
                    "hashValue": AnyCodable(.string(imageHash.value))
                ])
            if imageHash.algorithm == "unstated algorithm" {
                warnings.append(ParserWarning(severity: .warning, code: "custody.hash_no_algorithm",
                    message: "An image hash is recorded without naming its algorithm, so it "
                           + "cannot be independently reproduced."))
            }
        }
        // Always emitted, including when unstated — whether the records are live
        // or recovered changes what a finding means.
        add(.paragraph, "Record status: \(record.recordStatus.label)", field: "recordStatus",
            extra: ["recordStatus": AnyCodable(.string(record.recordStatus.rawValue))])
        fact("Examiner notes", record.notes, field: "notes")

        if !record.isComplete {
            warnings.append(ParserWarning(severity: .warning, code: "custody.incomplete",
                message: "Chain of custody is incomplete — no "
                       + record.missingFields.map(\.label).joined(separator: ", ")
                       + ". The evidence is still usable; it must not be described as "
                       + "having a complete chain."))
        }
        if record.recordStatus == .unstated {
            warnings.append(ParserWarning(severity: .warning, code: "custody.status_unstated",
                message: "The manifest does not say whether these records are live, "
                       + "recovered or deleted."))
        }

        // A manifest that decoded but carries no field at all is an empty
        // attestation, not a chain.
        let factBlocks = blocks.filter { $0.kind == .paragraph }
        if !record.isDocumented || factBlocks.count <= 1 {
            warnings.append(ParserWarning(severity: .warning, code: "custody.no_fields",
                message: "Custody manifest decoded but states no custody facts."))
            return document(.empty)
        }

        return document(warnings.isEmpty ? .complete : .partial)
    }
}
