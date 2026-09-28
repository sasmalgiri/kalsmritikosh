//
//  DeviceIdentity.swift
//  Kalsmritikosh
//
//  HOST-8d — the identity layer for DEVICES, so two extractions taken from the
//  same phone or laptop resolve to ONE subject instead of sitting side by side.
//
//  A device needs no new Entity.Kind and no new write door. It is exactly what
//  `identifierAnchor` was built for, in that case's own words: "ONE case,
//  specialized by DATA: the registry field id rides in attributes["anchorField"],
//  so every identifier-anchored subject shares this case while display + behavior
//  specialize by field." A device is a real-world subject identified by a
//  canonical identifier — a serial number, an IMEI, a UDID — which is the same
//  shape as a patent or a case number.
//
//  That choice buys three properties for free, all of them already tested:
//    • MERGE. `EntitiesRepository.resolveOrCreateAnchor` ends in
//      `ON CONFLICT(kind, normalized) DO UPDATE`, so the same serial seen in two
//      extractions resolves to the same entity id. That IS the merge HOST-8d
//      needs; nothing new had to be written for it.
//    • NO CONFLATION. Identity is (anchorField, canonicalValue) exactly, so a
//      serial and an IMEI that happen to share digits stay two devices.
//    • THE GATE. An anchor's display name is machine-built from displayLabel
//      constants, which is why the quality gate passes anchors by kind. That
//      matters here more than anywhere: a serial like `C02XY1234567` is mixed
//      letters and digits with no spaces, which is precisely the gate's
//      `hostname-shape` hard-junk rule. Routed as a `.person` or `.organization`
//      it would trip the write-door assertion; routed as an anchor it is correct.
//
//  Nothing in this file infers a device. Every identifier is read from a field an
//  artifact actually stated.
//

import Foundation

public enum DeviceIdentity {

    /// The identifier fields that can name a device, in descending order of how
    /// strongly they do so. A serial or IMEI is assigned by a manufacturer and is
    /// effectively unique; a computer name is user-chosen and reusable, so it is
    /// recorded but never treated as primary identity.
    public enum Field: String, Sendable, CaseIterable {
        case deviceSerialNumber
        case imei
        case meid
        case deviceUDID
        case deviceMACAddress
        case computerName
        case deviceProductType

        /// Whether this field alone is strong enough to merge two extractions.
        /// A computer name is not: two machines are routinely called "MacBook Pro".
        public var isStrongIdentity: Bool {
            switch self {
            case .deviceSerialNumber, .imei, .meid, .deviceUDID, .deviceMACAddress:
                return true
            case .computerName, .deviceProductType:
                return false
            }
        }

        /// The human label an anchor's display name is built from.
        public var label: String {
            switch self {
            case .deviceSerialNumber: return "Device serial"
            case .imei:               return "IMEI"
            case .meid:               return "MEID"
            case .deviceUDID:         return "Device UDID"
            case .deviceMACAddress:   return "Device MAC"
            case .computerName:       return "Computer name"
            case .deviceProductType:  return "Device model"
            }
        }

        /// The key names artifacts actually use, lowercased. Read from the
        /// artifacts this program already parses: an iOS backup's `Info.plist`,
        /// a Windows registry hive, and the examiner's custody manifest.
        var sourceKeys: [String] {
            switch self {
            case .deviceSerialNumber:
                return ["serial number", "serialnumber", "serial", "target identifier",
                        "bios serial number"]
            case .imei:
                return ["imei", "imei1", "imei 1"]
            case .meid:
                return ["meid"]
            case .deviceUDID:
                return ["unique identifier", "uniqueidentifier", "udid",
                        "unique device id", "machineguid"]
            case .deviceMACAddress:
                return ["wifi", "wifi address", "bluetooth", "mac address", "ethernet address"]
            case .computerName:
                return ["computername", "computer name", "device name", "display name",
                        "hostname", "localhostname"]
            case .deviceProductType:
                return ["product type", "producttype", "product name", "model",
                        "hardware model", "productversion"]
            }
        }
    }

    /// One identifier an artifact stated, ready for the anchor door.
    public struct Claim: Sendable, Equatable {
        public let field: Field
        /// Exactly as the artifact wrote it, for citation.
        public let statedValue: String
        /// The identity the anchor is keyed on.
        public let canonicalValue: String

        public nonisolated var identityKey: String {
            IdentifierAnchor.identityKey(field: field.rawValue, value: statedValue)
        }
        public nonisolated var displayName: String {
            "\(field.label) \(canonicalValue)"
        }
    }

    // MARK: - Reading identifiers an artifact stated

    /// Device identifiers from the examiner's chain of custody. The custody
    /// record is the most authoritative source in the archive, because a person
    /// attested to it.
    public nonisolated static func claims(from custody: CustodyRecord) -> [Claim] {
        var claims: [Claim] = []
        // The manifest has one identifier field, and does not say WHICH kind it
        // is. Classified by shape rather than assumed to be a serial: a
        // 15-digit number is an IMEI, and calling it a serial would be wrong.
        if let identifier = custody.sourceDeviceIdentifier {
            let field = classify(identifier: identifier)
            if let claim = makeClaim(field: field, stated: identifier) { claims.append(claim) }
        }
        if let device = custody.sourceDevice,
           let claim = makeClaim(field: .deviceProductType, stated: device) {
            claims.append(claim)
        }
        return claims
    }

    /// Device identifiers from key/value pairs — the shape both the plist lane
    /// (an iOS backup's Info.plist) and the registry lane emit. Keys are matched
    /// on their LAST path component, so `HKLM\...\ComputerName\ComputerName`
    /// matches as readily as a bare `ComputerName`.
    public nonisolated static func claims(fromKeyValues pairs: [(key: String, value: String)]) -> [Claim] {
        var seen = Set<String>()
        var claims: [Claim] = []
        for (rawKey, rawValue) in pairs {
            let leaf = rawKey
                .split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == "." })
                .last.map(String.init) ?? rawKey
            let key = leaf.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let field = Field.allCases.first(where: { $0.sourceKeys.contains(key) }),
                  let claim = makeClaim(field: field, stated: rawValue),
                  seen.insert(claim.identityKey).inserted else { continue }
            claims.append(claim)
        }
        return claims
    }

    /// Which kind of identifier a bare value is, by SHAPE. Returns `.deviceSerialNumber`
    /// only when the value is not recognizably something more specific — the
    /// fallback is the weakest claim, never the strongest.
    nonisolated static func classify(identifier raw: String) -> Field {
        let digitsOnly = raw.filter(\.isNumber)
        let compact = raw.replacingOccurrences(of: " ", with: "")
        // IMEI: exactly 15 digits, and nothing else.
        if digitsOnly.count == 15, compact.allSatisfy(\.isNumber) { return .imei }
        // MEID: 14 hex characters.
        if compact.count == 14, compact.allSatisfy(\.isHexDigit) { return .meid }
        // iOS UDID: 40 hex, or the newer 24-char form with a dash after 8.
        if compact.count == 40, compact.allSatisfy(\.isHexDigit) { return .deviceUDID }
        if compact.count == 25, compact.dropFirst(8).first == "-" { return .deviceUDID }
        // MAC address: six colon- or dash-separated hex pairs.
        let separators = compact.filter { $0 == ":" || $0 == "-" }.count
        if separators == 5, compact.count == 17 { return .deviceMACAddress }
        return .deviceSerialNumber
    }

    /// Builds a claim, refusing values that cannot identify anything. Returning
    /// nil here is the honest outcome: a blank or single-character identifier
    /// would create an anchor that silently merges unrelated devices.
    nonisolated static func makeClaim(field: Field, stated: String) -> Claim? {
        let trimmed = stated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonical = IdentifierAnchor.canonicalValue(trimmed)
        guard canonical.count >= 2 else { return nil }
        // Placeholder values manufacturers and tools leave behind. Anchoring on
        // one would merge every device that shares the placeholder into a single
        // subject. Compared CANONICALLY on both sides, because the canonicaliser
        // strips label words: "System Serial Number" becomes "systemserial", so a
        // list written in raw form would never match what it is checked against.
        guard !canonicalPlaceholders.contains(canonical.lowercased()) else { return nil }
        return Claim(field: field, statedValue: trimmed, canonicalValue: canonical)
    }

    /// Values that look like identifiers but identify nothing, written the way an
    /// artifact writes them. Run through the SAME canonicaliser before comparison
    /// so the two sides always agree.
    nonisolated static let placeholders: [String] = [
        "Unknown", "None", "Null", "N/A", "NA", "Not Available", "Not Set",
        "To Be Filled By O.E.M.", "System Serial Number", "Default",
        "0", "00000000", "000000000000000", "FFFFFFFFFFFFFFFF",
        "Serial Number", "Device Serial Number", "Default string", "Chassis Serial Number"
    ]

    /// The placeholder set as the canonicaliser sees it.
    nonisolated static let canonicalPlaceholders: Set<String> = Set(
        placeholders.map { IdentifierAnchor.canonicalValue($0).lowercased() }
    )

    /// The strongest claim in a set, or nil when only weak ones are present.
    /// This is what decides whether two extractions may be merged at all.
    public nonisolated static func strongestIdentity(in claims: [Claim]) -> Claim? {
        for field in Field.allCases where field.isStrongIdentity {
            if let match = claims.first(where: { $0.field == field }) { return match }
        }
        return nil
    }

    /// Whether two claim sets describe the same device. True only on a STRONG
    /// field matching exactly; a shared computer name or model is never enough,
    /// because two machines are routinely called the same thing.
    public nonisolated static func describeSameDevice(_ a: [Claim], _ b: [Claim]) -> Bool {
        let strongA = Set(a.filter { $0.field.isStrongIdentity }.map(\.identityKey))
        let strongB = Set(b.filter { $0.field.isStrongIdentity }.map(\.identityKey))
        return !strongA.isEmpty && !strongA.isDisjoint(with: strongB)
    }
}
