//
//  NSFReader.swift
//  Kalsmritikosh
//
//  Lotus Notes / IBM Domino NSF database reader. Produces a stream of
//  NSFNote records — each note's MAPI-ish "items" dictionary maps
//  field names like Subject, Body, From, SendTo, DeliveredDate to
//  their string values. The email-loader path turns mail-shaped notes
//  (Form=Memo / Reply / Notice) into KnowledgeObjects.
//
//  NSF doesn't have a stable open spec the way PST/[MS-PST] does;
//  this reader is best-effort: it tries a structured pass first
//  (scan for valid item-record headers in the database body), and
//  falls back to a text-mode scan when the structured pass yields
//  nothing. Ported from sibling mailin/NSFParser.
//

import Foundation
import OSLog

/// Single-thread (synchronous) reader for an NSF / NSF8 / NSF9
/// archive. Construct, call `readNotes`, done.
public nonisolated struct NSFReader: Sendable {
    private let data: Data
    private static let log = Logger(subsystem: "kalsmritikosh", category: "NSFReader")
    private static let maxNotes = 500_000

    /// One parsed note: free-form `items` dictionary (field → value)
    /// plus surfaced category tags. `isMailNote` filters down to the
    /// notes that look like email memos.
    public struct NSFNote: Sendable {
        public var items: [String: String] = [:]
        public var categories: [String] = []

        public init() {}

        public var isMailNote: Bool {
            let form = (items["Form"] ?? "").lowercased()
            if form == "memo" || form == "reply" || form == "notice" || form.contains("mail") {
                return true
            }
            // Some senders don't ship a Form field — accept on a
            // From-ish header AND a destination/subject combination.
            if items["From"] != nil || items["$From"] != nil || items["SMTPOriginator"] != nil {
                if items["SendTo"] != nil || items["EnterSendTo"] != nil || items["Subject"] != nil {
                    return true
                }
            }
            return false
        }
    }

    public enum NSFError: Error, Sendable {
        case invalidFormat(String)
    }

    public init(data: Data) { self.data = data }

    public func readNotes() throws -> [NSFNote] {
        guard data.count >= 256 else {
            throw NSFError.invalidFormat("File too small")
        }
        let signature = Self.readUInt16(data, offset: 0)
        let validSignatures: Set<UInt16> = [0x001A, 0x1A00]
        guard validSignatures.contains(signature) || isLikelyNSF() else {
            throw NSFError.invalidFormat(
                "Not a valid NSF file (signature: 0x\(String(format: "%04X", signature)))"
            )
        }
        if let notes = try? parseStructured(), !notes.isEmpty {
            return notes
        }
        return try parseByScan()
    }

    // MARK: - Heuristic format check

    private func isLikelyNSF() -> Bool {
        guard data.count > 100 else { return false }
        let headerChunk = String(data: data[0..<min(512, data.count)], encoding: .ascii) ?? ""
        return headerChunk.contains("NSF")
            || headerChunk.contains("Notes")
            || headerChunk.contains("Lotus")
    }

    // MARK: - Structured (preferred) pass

    private func parseStructured() throws -> [NSFNote] {
        guard data.count >= 0x2C else {
            throw NSFError.invalidFormat("Header too small for structured parse")
        }
        // The NSF header carries a database-info offset around 0x28;
        // use it as a hint for where note records likely start. We
        // still floor at 256 to skip the header proper.
        let dbInfoOffset: Int = data.count > 0x30
            ? Int(Self.readUInt32(data, offset: 0x28))
            : 0
        var notes: [NSFNote] = []
        var offset = max(dbInfoOffset, 256)
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 100_000

        while offset < data.count - 64
            && notes.count < Self.maxNotes
            && consecutiveFailures < maxConsecutiveFailures {
            if let (note, nextOffset) = readNoteRecord(at: offset), nextOffset > offset {
                notes.append(note)
                offset = nextOffset
                consecutiveFailures = 0
            } else {
                offset += 1
                consecutiveFailures += 1
            }
        }
        return notes
    }

    /// One pass over the candidate note records starting at `offset`.
    /// Returns nil when the bytes don't look like an NSF item header,
    /// letting the caller advance and retry.
    private func readNoteRecord(at offset: Int) -> (NSFNote, Int)? {
        guard offset + 32 <= data.count else { return nil }
        let itemType = Self.readUInt16(data, offset: offset)
        // The known item-type tags. Each value carries both the LE
        // and BE form in case the file's byte order disagrees.
        let validItemTypes: Set<UInt16> = [
            0x0500, 0x0501, 0x0300, 0x0400, 0x0100,
            0x0005, 0x0105, 0x0003, 0x0004, 0x0001,
        ]
        guard validItemTypes.contains(itemType)
            || validItemTypes.contains(itemType.byteSwapped) else {
            return nil
        }
        let nameLen = Int(Self.readUInt16(data, offset: offset + 2))
        guard nameLen > 0 && nameLen < 256 else { return nil }
        let (headerPlusName, overflow) = offset.addingReportingOverflow(8 + nameLen)
        guard !overflow, headerPlusName <= data.count else { return nil }
        let nameStart = offset + 8
        guard let name = readLMBCSString(at: nameStart, length: nameLen) else { return nil }
        // Only accept known field names or general identifier-shaped
        // names ($prefixed, alnum/_). Anything else is almost
        // certainly random binary garbage.
        let knownNames: Set<String> = [
            "Form", "Subject", "Body", "From", "$From", "SendTo", "CopyTo",
            "BlindCopyTo", "DeliveredDate", "PostedDate", "$MessageID",
            "EnterSendTo", "EnterCopyTo", "Categories", "$Ref", "UNID",
            "$HtmlBody", "Body_HTML", "SMTPOriginator", "$FILE"
        ]
        guard knownNames.contains(name)
            || name.hasPrefix("$")
            || name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }

        var note = NSFNote()
        var pos = offset
        while pos < data.count - 8 && note.items.count < 200 {
            guard let (itemName, itemValue, nextPos) = readItem(at: pos) else { break }
            if itemName == "Categories" {
                note.categories = itemValue
                    .components(separatedBy: CharacterSet(charactersIn: ",;"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if itemName != "$FILE"
                && !itemName.hasPrefix("$FILE_")
                && itemName != "$AttachmentData" {
                note.items[itemName] = itemValue
            }
            pos = nextPos
            // Notes are delimited by Form changes — when we've already
            // seen the Form item and accumulated other fields, the
            // next record likely belongs to the next note.
            if itemName == "Form" && note.items.count > 1 { break }
        }
        guard !note.items.isEmpty else { return nil }
        return (note, pos)
    }

    private func readItem(at offset: Int) -> (String, String, Int)? {
        guard offset + 8 <= data.count else { return nil }
        let nameLen = Int(Self.readUInt16(data, offset: offset + 2))
        guard nameLen > 0 && nameLen < 256 else { return nil }
        let (headerPlusName, overflow) = offset.addingReportingOverflow(8 + nameLen)
        guard !overflow, headerPlusName <= data.count else { return nil }
        let valueLenRaw = Int(Self.readUInt32(data, offset: offset + 4))
        let maxValueLen = data.count - headerPlusName
        let valueLen = min(valueLenRaw, maxValueLen)
        guard valueLen >= 0 && valueLen < 10_000_000 else { return nil }
        let nameStart = offset + 8
        guard let name = readLMBCSString(at: nameStart, length: nameLen) else { return nil }
        let valueStart = nameStart + nameLen
        guard valueStart + valueLen <= data.count else { return nil }

        let value: String
        if valueLen > 0 {
            let valueData = data[valueStart..<(valueStart + valueLen)]
            if name == "Body" || name == "$HtmlBody" || name == "Body_HTML" {
                value = decodeBodyValue(valueData)
            } else {
                value = String(data: valueData, encoding: .utf8)
                    ?? String(data: valueData, encoding: .isoLatin1)
                    ?? ""
            }
        } else {
            value = ""
        }
        return (name, value.trimmingCharacters(in: .controlCharacters), valueStart + valueLen)
    }

    /// Body fields can arrive in three shapes: plain UTF-8, an LZSS
    /// blob with a 4-byte expected-size prefix, or a CD composite-
    /// record sequence. Try each in turn so we hand the chunker the
    /// best human-readable text we can.
    private func decodeBodyValue(_ valueData: Data) -> String {
        if let text = String(data: valueData, encoding: .utf8), !text.isEmpty {
            return text
        }
        if let decompressed = lzssDecompress(valueData),
           let text = String(data: decompressed, encoding: .utf8)
            ?? String(data: decompressed, encoding: .isoLatin1) {
            return text
        }
        if valueData.count >= 4 {
            let stripped = stripCompositeHeader(valueData)
            if let text = String(data: stripped, encoding: .utf8)
                ?? String(data: stripped, encoding: .isoLatin1),
               !text.trimmingCharacters(in: .controlCharacters).isEmpty {
                return text
            }
        }
        return String(data: valueData, encoding: .isoLatin1) ?? ""
    }

    private func stripCompositeHeader(_ data: Data) -> Data {
        guard data.count > 8 else { return data }
        var offset = 0
        while offset + 4 <= data.count {
            let sig = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let len = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
            if sig == 0x0000 && len == 0x0000 { break }
            // 0x0005 / 0x0500: TEXT record — payload starts after the
            // 4-byte sig+len header.
            if sig == 0x0005 || sig == 0x0500 {
                let textStart = offset + 4
                if textStart < data.count {
                    return Data(data[textStart...])
                }
            }
            offset += max(4 + Int(len), 4)
        }
        return data
    }

    /// LZSS variant used by Notes Body fields. 4-byte LE expected
    /// size prefix, then 8-symbol blocks with a control byte: each
    /// bit set means "next byte is literal", each cleared means
    /// "next two bytes are an (offset, length) back-reference into
    /// a 4 KB sliding dictionary preinitialized with 0x20 (space)".
    private func lzssDecompress(_ input: Data) -> Data? {
        guard input.count > 4 else { return nil }
        let expectedSize = Int(
            UInt32(input[0])
            | (UInt32(input[1]) << 8)
            | (UInt32(input[2]) << 16)
            | (UInt32(input[3]) << 24)
        )
        guard expectedSize > 0 && expectedSize < 50_000_000 else { return nil }

        var output = Data(capacity: expectedSize)
        var window = [UInt8](repeating: 0x20, count: 4096)
        var windowPos = 1
        var inputPos = 4
        while inputPos < input.count && output.count < expectedSize {
            let flags = input[inputPos]; inputPos += 1
            for bit in 0..<8 {
                guard inputPos < input.count && output.count < expectedSize else { break }
                if flags & (1 << bit) != 0 {
                    output.append(input[inputPos])
                    window[windowPos % 4096] = input[inputPos]
                    windowPos += 1
                    inputPos += 1
                } else {
                    guard inputPos + 1 < input.count else { break }
                    let b1 = Int(input[inputPos])
                    let b2 = Int(input[inputPos + 1])
                    inputPos += 2
                    let offset = b1 | ((b2 & 0xF0) << 4)
                    let length = (b2 & 0x0F) + 3
                    for i in 0..<length {
                        guard output.count < expectedSize else { break }
                        let byte = window[(offset + i) % 4096]
                        output.append(byte)
                        window[windowPos % 4096] = byte
                        windowPos += 1
                    }
                }
            }
        }
        return output.isEmpty ? nil : output
    }

    // MARK: - Scan-based fallback

    /// Used when the structured pass returns zero notes — older or
    /// proprietary NSF variants can defeat the item-header scan.
    /// This path treats the file as decoded text and groups lines
    /// into note blocks bounded by `Form: Memo` / `Form: Reply` etc.
    private func parseByScan() throws -> [NSFNote] {
        var notes: [NSFNote] = []
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .windowsCP1252) else {
            throw NSFError.invalidFormat("Cannot decode file content")
        }
        for block in extractNoteBlocks(from: text) {
            var note = NSFNote()
            for line in block.components(separatedBy: .newlines) {
                if let (key, value) = parseFieldLine(line) {
                    if key == "Categories" {
                        note.categories = value
                            .components(separatedBy: CharacterSet(charactersIn: ",;"))
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    } else {
                        note.items[key] = value
                    }
                }
            }
            if note.isMailNote { notes.append(note) }
        }
        return notes
    }

    private func extractNoteBlocks(from text: String) -> [String] {
        var blocks: [String] = []
        var currentBlock = ""
        var foundFirstForm = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            let isFormBoundary = trimmed.hasPrefix("Form")
                && (trimmed.contains(":") || trimmed.contains("="))
                && (lower.contains("memo") || lower.contains("reply")
                    || lower.contains("notice") || lower.contains("mail"))
            if isFormBoundary {
                if foundFirstForm && !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                }
                currentBlock = line + "\n"
                foundFirstForm = true
            } else if foundFirstForm {
                currentBlock += line + "\n"
            }
        }
        if !currentBlock.isEmpty { blocks.append(currentBlock) }
        return blocks
    }

    private func parseFieldLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for sep: Character in [":", "="] {
            if let idx = trimmed.firstIndex(of: sep) {
                let key = String(trimmed[trimmed.startIndex..<idx])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: idx)...])
                    .trimmingCharacters(in: .whitespaces)
                let knownFields: Set<String> = [
                    "Form", "Subject", "Body", "From", "$From", "SendTo", "CopyTo",
                    "BlindCopyTo", "DeliveredDate", "PostedDate", "$MessageID",
                    "EnterSendTo", "EnterCopyTo", "Categories", "$Ref",
                    "$HtmlBody", "Body_HTML", "SMTPOriginator", "UNID"
                ]
                if knownFields.contains(key) && !value.isEmpty {
                    return (key, value)
                }
            }
        }
        return nil
    }

    // MARK: - Binary helpers

    /// LMBCS (Lotus Multi-Byte Character Set) — simplified as
    /// UTF-8/Latin1 for common cases. A full LMBCS decoder isn't worth
    /// the maintenance burden for the email-ingest use case.
    private func readLMBCSString(at offset: Int, length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        let slice = data[offset..<(offset + length)]
        return (String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .isoLatin1))?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    nonisolated static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    nonisolated static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
