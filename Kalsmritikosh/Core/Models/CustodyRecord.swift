//
//  CustodyRecord.swift
//  Kalsmritikosh
//
//  HOST-8 — the chain of custody for an examiner-supplied extraction.
//
//  Everything the HOST-* and DISC-* lanes built reads evidence. This records
//  WHERE THE EVIDENCE CAME FROM: who acquired it, when, with which tool, from
//  which device, under what authority, and whether the records inside are live,
//  recovered or deleted. Without it the archive is a very good search index over
//  a folder. With it, every answer can say what it is answering FROM.
//
//  Two design choices carry the honesty of this file:
//
//  1. NOTHING IS INFERRED. Not the examiner, not the tool, not the acquisition
//     date. Custody is a human attestation; a value we guessed and presented
//     beside real ones would be worse than a gap, because it would look the same.
//
//  2. ABSENCE IS A STATE, NOT A DEFAULT. `CustodyRecord.undocumented` is a real
//     value the ledger can hold and an answer can disclose, so evidence with no
//     recorded custody never renders identically to evidence with a full chain.
//
//  The examiner writes a small JSON sidecar at the extraction root. Every field
//  is optional — four of them still produce a usable chain — and the parser
//  reports which ones are missing rather than quietly accepting a thin record.
//

import Foundation

public struct CustodyRecord: Sendable, Equatable {

    /// Whether the records inside the extraction are live data, recovered from
    /// unallocated space, deleted-but-present, or a mix. This changes what a
    /// finding means in a proceeding, so it is stated rather than assumed.
    public enum RecordStatus: String, Sendable, Equatable, CaseIterable {
        case live, recovered, deleted, mixed, unstated

        public var label: String {
            switch self {
            case .live:      return "live data"
            case .recovered: return "recovered from unallocated space"
            case .deleted:   return "deleted but still present"
            case .mixed:     return "mixed live and recovered"
            case .unstated:  return "record status not stated"
            }
        }
    }

    public struct Hash: Sendable, Equatable {
        public let algorithm: String
        public let value: String

        public nonisolated init(algorithm: String, value: String) {
            self.algorithm = algorithm; self.value = value
        }
    }

    public let caseNumber: String?
    public let evidenceNumber: String?
    public let examiner: String?
    public let agency: String?
    /// The legal basis — warrant number, consent reference, court order. Recorded
    /// verbatim as written; never interpreted or validated as authority.
    public let authority: String?
    public let acquisitionTool: String?
    public let acquisitionDate: Date?
    public let sourceDevice: String?
    public let sourceDeviceIdentifier: String?
    /// The time zone the SOURCE device was set to, which is what makes its local
    /// timestamps interpretable.
    public let sourceTimeZone: String?
    public let imageHash: Hash?
    public let recordStatus: RecordStatus
    public let notes: String?

    public nonisolated init(
        caseNumber: String? = nil, evidenceNumber: String? = nil, examiner: String? = nil,
        agency: String? = nil, authority: String? = nil, acquisitionTool: String? = nil,
        acquisitionDate: Date? = nil, sourceDevice: String? = nil,
        sourceDeviceIdentifier: String? = nil, sourceTimeZone: String? = nil,
        imageHash: Hash? = nil, recordStatus: RecordStatus = .unstated, notes: String? = nil
    ) {
        self.caseNumber = caseNumber
        self.evidenceNumber = evidenceNumber
        self.examiner = examiner
        self.agency = agency
        self.authority = authority
        self.acquisitionTool = acquisitionTool
        self.acquisitionDate = acquisitionDate
        self.sourceDevice = sourceDevice
        self.sourceDeviceIdentifier = sourceDeviceIdentifier
        self.sourceTimeZone = sourceTimeZone
        self.imageHash = imageHash
        self.recordStatus = recordStatus
        self.notes = notes
    }

    /// Evidence with NO custody attestation. A first-class value so the ledger can
    /// hold it and an answer can disclose it, rather than absence looking the same
    /// as documentation.
    public nonisolated static let undocumented = CustodyRecord()

    public nonisolated var isDocumented: Bool { self != .undocumented }

    // MARK: - Completeness

    /// The fields that make a chain of custody stand up. Reported, never enforced:
    /// an incomplete chain is still evidence, it just must not be presented as a
    /// complete one.
    public enum Field: String, Sendable, CaseIterable {
        case caseNumber, evidenceNumber, examiner, authority
        case acquisitionTool, acquisitionDate, sourceDevice, imageHash

        public var label: String {
            switch self {
            case .caseNumber:      return "case number"
            case .evidenceNumber:  return "evidence number"
            case .examiner:        return "examiner"
            case .authority:       return "legal authority"
            case .acquisitionTool: return "acquisition tool"
            case .acquisitionDate: return "acquisition date"
            case .sourceDevice:    return "source device"
            case .imageHash:       return "image hash"
            }
        }
    }

    public nonisolated var missingFields: [Field] {
        Field.allCases.filter { field in
            switch field {
            case .caseNumber:      return caseNumber == nil
            case .evidenceNumber:  return evidenceNumber == nil
            case .examiner:        return examiner == nil
            case .authority:       return authority == nil
            case .acquisitionTool: return acquisitionTool == nil
            case .acquisitionDate: return acquisitionDate == nil
            case .sourceDevice:    return sourceDevice == nil
            case .imageHash:       return imageHash == nil
            }
        }
    }

    /// True only when every field above is present. Deliberately strict: "complete
    /// chain of custody" is a claim with consequences, so it is all-or-nothing.
    public nonisolated var isComplete: Bool { missingFields.isEmpty }

    /// One line an answer can carry as a provenance footer.
    public nonisolated var disclosure: String {
        guard isDocumented else {
            return "No chain of custody recorded for this evidence."
        }
        var parts: [String] = []
        if let evidenceNumber { parts.append("evidence \(evidenceNumber)") }
        if let caseNumber { parts.append("case \(caseNumber)") }
        if let examiner { parts.append("acquired by \(examiner)") }
        if let acquisitionTool { parts.append("using \(acquisitionTool)") }
        if let acquisitionDate {
            parts.append("on \(Self.iso8601.string(from: acquisitionDate))")
        }
        if let sourceDevice { parts.append("from \(sourceDevice)") }
        if let authority { parts.append("under \(authority)") }
        var line = parts.isEmpty ? "Chain of custody recorded" : parts.joined(separator: ", ")
        if recordStatus != .unstated { line += " — \(recordStatus.label)" }
        if !isComplete {
            line += ". Incomplete chain: no "
                + missingFields.map(\.label).joined(separator: ", ") + "."
        }
        return line
    }

    // MARK: - Decoding

    /// Parses the examiner's JSON sidecar. Returns nil when the bytes are not a
    /// JSON object — reported by the caller rather than degraded into an empty
    /// record, because "no custody file" and "unreadable custody file" are
    /// different facts.
    public nonisolated static func decode(_ data: Data) -> CustodyRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = object[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }

        var hash: Hash?
        if let nested = object["imageHash"] as? [String: Any],
           let value = (nested["value"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            // An algorithm is required to state a hash: a bare digest an examiner
            // cannot reproduce is not verification.
            let algorithm = (nested["algorithm"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            hash = Hash(algorithm: algorithm?.isEmpty == false ? algorithm! : "unstated algorithm",
                        value: value)
        }

        let status = RecordStatus(rawValue: (string("recordStatus") ?? "").lowercased())
            ?? .unstated

        return CustodyRecord(
            caseNumber: string("caseNumber", "case"),
            evidenceNumber: string("evidenceNumber", "evidence"),
            examiner: string("examiner"),
            agency: string("agency", "organisation", "organization"),
            authority: string("authority", "legalAuthority", "warrant"),
            acquisitionTool: string("acquisitionTool", "tool"),
            acquisitionDate: string("acquisitionDate", "acquired").flatMap(parseDate),
            sourceDevice: string("sourceDevice", "device"),
            sourceDeviceIdentifier: string("sourceDeviceIdentifier", "serialNumber", "imei"),
            sourceTimeZone: string("sourceTimeZone", "timeZone"),
            imageHash: hash,
            recordStatus: status,
            notes: string("notes"))
    }

    /// RFC 3339, with or without fractional seconds, or a bare date. A value in
    /// any other shape yields nil: an acquisition date is a legal fact, and a
    /// guessed one is worse than a missing one.
    nonisolated static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The filenames an examiner may use for the sidecar, lowercased.
    public nonisolated static let manifestNames: Set<String> = [
        "kalsmritikosh-custody.json", "custody.json", "chain-of-custody.json"
    ]
}
