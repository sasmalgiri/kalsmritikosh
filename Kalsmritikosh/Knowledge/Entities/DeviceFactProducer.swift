//
//  DeviceFactProducer.swift
//  Kalsmritikosh
//
//  HOST-8e — the wiring that makes HOST-8d run. It turns the device identifiers
//  an artifact stated into GenericFacts, and then does nothing else, because
//  nothing else is needed:
//
//    `IngestCoordinator.bindIdentifierAnchors` already resolves-or-creates an
//    anchor for EVERY fact whose field is `.identifier`-shaped. Registering the
//    strong device fields with that shape means device facts travel the existing
//    gated door, get the existing per-document anchor cache, and merge across
//    extractions by the existing ON CONFLICT — with no new call site in the
//    pipeline and no new write path to audit.
//
//  Why a producer rather than an extension of DomainFactExtractor: that extractor
//  reads free TEXT, and a serial number regexed out of prose is noise. Device
//  identifiers live in structured key/value blocks — an iOS backup's Info.plist,
//  a registry value, the examiner's custody manifest — where the key NAMES the
//  field. Reading them there is exact; reading them from prose would be a guess.
//
//  The weak fields (computer name, model) are produced as `.text` facts on
//  purpose. They are worth recording and citing, but they must not create an
//  anchor: two machines are routinely called "MacBook Pro", and merging on that
//  would fuse unrelated devices into one subject.
//

import Foundation

public struct DeviceFactProducer: Sendable {

    /// Bumped when this producer's output changes, so a re-ingest can tell its
    /// own rows apart from an older generation's.
    public nonisolated static let producerVersion = 1

    public nonisolated init() {}

    /// Device facts from a parsed document. Returns empty for any document that
    /// does not state a device identifier, which is almost all of them — this
    /// runs on every ingest, so it must be cheap and silent when irrelevant.
    public nonisolated func facts(from doc: ParsedDocument, subjectLabel: String) -> [GenericFact] {
        let claims: [DeviceIdentity.Claim]
        switch doc.detectedType {
        case .custodyManifest:
            claims = DeviceIdentity.claims(from: Self.custodyRecord(from: doc))
        case .plist, .registryHive, .extractionManifest:
            claims = DeviceIdentity.claims(fromKeyValues: Self.keyValues(from: doc))
        default:
            // Deliberately nothing. A device identifier appearing in a PDF or an
            // email is prose, and anchoring a device on prose would be a guess.
            return []
        }
        guard !claims.isEmpty else { return [] }

        // The block a claim came from, so each fact cites the exact row it was
        // read from rather than the whole document.
        let blockByValue = Self.blockIndex(of: doc)
        return claims.map { claim in
            let blockIDs = blockByValue[claim.statedValue].map { [$0] } ?? []
            return GenericFact(
                subjectLabel: subjectLabel,
                field: claim.field.rawValue,
                value: claim.statedValue,
                assessment: EvidenceAssessment(
                    // The artifact STATED this; we did not derive or infer it.
                    basis: .sourceAsserted,
                    origin: .sourceExtraction),
                // High, but not certain: the artifact's own accuracy is what is
                // being trusted, and a cloned or reflashed device can carry a
                // serial that no longer matches its hardware.
                confidence: 0.9,
                sourceBlockIDs: blockIDs,
                producerVersion: Self.producerVersion,
                rawMatch: claim.statedValue)
        }
    }

    // MARK: - Reading the document

    /// Key/value pairs from a plist, registry or manifest document. Uses the
    /// discrete `value` attribute the parsers now carry, never re-splitting a
    /// rendered prose line — string surgery on our own output would break the
    /// moment the rendering changed.
    nonisolated static func keyValues(from doc: ParsedDocument) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for block in doc.blocks {
            func attribute(_ name: String) -> String? {
                if case .string(let v)? = block.attributes[name]?.value, !v.isEmpty { return v }
                return nil
            }
            guard let value = attribute("value") else { continue }
            // plist rows carry keyPath; registry rows carry valueName plus the
            // full registryPath, and the leaf of either is the field name.
            guard let key = attribute("keyPath") ?? attribute("valueName")
                    ?? attribute("registryPath") else { continue }
            pairs.append((key: key, value: value))
        }
        return pairs
    }

    /// Rebuilds the custody record from the document's own blocks, so the
    /// producer reads what the parser recorded rather than re-parsing the file.
    nonisolated static func custodyRecord(from doc: ParsedDocument) -> CustodyRecord {
        var identifier: String?
        var device: String?
        for block in doc.blocks {
            guard case .string(let field)? = block.attributes["custodyField"]?.value else { continue }
            // "Label: value" is the parser's own shape for a custody fact, and the
            // label is a constant this file does not need to know — everything
            // after the first ": " is the value.
            guard let separator = block.rawText.range(of: ": ") else { continue }
            let value = String(block.rawText[separator.upperBound...])
            switch field {
            case "sourceDeviceIdentifier": identifier = value
            case "sourceDevice":           device = value
            default: break
            }
        }
        return CustodyRecord(sourceDevice: device, sourceDeviceIdentifier: identifier)
    }

    /// Maps a stated value back to the block that carried it, so the fact's
    /// citation points at the row and not the file.
    nonisolated static func blockIndex(of doc: ParsedDocument) -> [String: UUID] {
        var index: [String: UUID] = [:]
        for block in doc.blocks {
            if case .string(let value)? = block.attributes["value"]?.value, index[value] == nil {
                index[value] = block.id
            }
            // Custody blocks render as "Label: value".
            if block.attributes["custodyField"] != nil,
               let separator = block.rawText.range(of: ": ") {
                let value = String(block.rawText[separator.upperBound...])
                if index[value] == nil { index[value] = block.id }
            }
        }
        return index
    }
}
