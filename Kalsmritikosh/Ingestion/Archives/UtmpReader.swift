//
//  UtmpReader.swift
//  Kalsmritikosh
//
//  HOST-4 — reader for the Linux login-accounting files: `utmp`, `wtmp`, `btmp`
//  (and their rotated `.1` siblings). Pure Swift, read-only, no dependency.
//
//  These are the Linux answer to "who was on this machine, and when" — the
//  equivalent of Windows 4624/4625. Unlike an event log they are FULLY readable:
//  each file is an array of fixed-size `struct utmp` records with no templates,
//  no compression and no self-reference, so every field can be decoded exactly
//  and checked against an independently-built fixture.
//
//  Layout (glibc `struct utmp`, 384 bytes on EVERY architecture — glibc pins the
//  time and session fields to 32 bits precisely so the file is portable):
//
//    0    ut_type        int16   + 2 bytes padding
//    4    ut_pid         int32
//    8    ut_line[32]    tty / pts the session used
//    40   ut_id[4]       init id
//    44   ut_user[32]    account name
//    76   ut_host[256]   remote hostname, if the login came over the network
//    332  ut_exit        two int16 (termination, exit)
//    336  ut_session     int32
//    340  ut_tv          two int32: tv_sec, tv_usec
//    348  ut_addr_v6[16] four int32: the remote address
//    364  __unused[20]
//
//  BYTE ORDER is the host's, and nothing in the file declares it. Rather than
//  assume little-endian, both readings are scored on whether record types and
//  timestamps come out plausible, and the winner is recorded. A file that reads
//  as neither is refused instead of being rendered as garbage.
//
//  The 2038 limit is real and inherent: `tv_sec` is a signed 32-bit count, so
//  this format cannot express a time past 2038-01-19. That is a property of the
//  evidence, not of this reader.
//

import Foundation

public struct UtmpReader: Sendable {

    /// What the record is. The forensic meaning of a file depends on these far
    /// more than on the text fields: a BOOT_TIME record dates a power-on, a
    /// USER_PROCESS dates a login, a DEAD_PROCESS dates its end.
    public enum Kind: Int32, Sendable, CaseIterable {
        case empty = 0
        case runLevel = 1
        case bootTime = 2
        case newTime = 3
        case oldTime = 4
        case initProcess = 5
        case loginProcess = 6
        case userProcess = 7
        case deadProcess = 8
        case accounting = 9

        /// Plain-language label. Deliberately NOT "logged in" — whether a record
        /// means a success or a failure depends on WHICH FILE it came from, which
        /// the bytes do not state. See `UtmpFile`.
        public var label: String {
            switch self {
            case .empty: return "empty slot"
            case .runLevel: return "runlevel change"
            case .bootTime: return "system boot"
            case .newTime: return "clock set (new time)"
            case .oldTime: return "clock set (old time)"
            case .initProcess: return "init process"
            case .loginProcess: return "login process waiting"
            case .userProcess: return "session"
            case .deadProcess: return "session ended"
            case .accounting: return "accounting"
            }
        }
    }

    /// Which accounting file this is. The three files share one record layout and
    /// mean COMPLETELY different things, and that meaning lives only in the
    /// filename. Rendering a `btmp` record as a login would invert the evidence:
    /// a failed break-in attempt would read as a successful sign-in.
    public enum UtmpFile: Sendable {
        /// `/var/run/utmp` — who was logged in AT THE MOMENT of acquisition.
        case currentlyLoggedIn
        /// `/var/log/wtmp` — the historical login/logout/boot record.
        case loginHistory
        /// `/var/log/btmp` — FAILED login attempts.
        case failedAttempts

        public var whatTheFileIs: String {
            switch self {
            case .currentlyLoggedIn:
                return "sessions open at the moment the machine was imaged"
            case .loginHistory:
                return "historical logins, logouts, boots and shutdowns"
            case .failedAttempts:
                return "FAILED login attempts (a record here is a rejected sign-in, not a successful one)"
            }
        }

        /// Classify by filename, which is the only place the distinction exists.
        /// Rotated files (`wtmp.1`, `btmp.2.gz` → `btmp.2`) keep their meaning.
        public nonisolated static func classify(filename: String) -> UtmpFile? {
            let name = (filename as NSString).lastPathComponent.lowercased()
            let base = name.split(separator: ".").first.map(String.init) ?? name
            switch base {
            case "utmp", "utmpx": return .currentlyLoggedIn
            case "wtmp", "wtmpx": return .loginHistory
            case "btmp", "btmpx": return .failedAttempts
            default: return nil
            }
        }
    }

    public struct Record: Sendable, Equatable {
        public let kind: Kind
        public let pid: Int32
        /// The tty or pseudo-terminal, e.g. `pts/0`, `tty1`. Empty for boots.
        public let line: String
        public let id: String
        public let user: String
        /// Remote hostname for a network login; empty for a console login.
        public let host: String
        public let session: Int32
        /// When the record was written. The load-bearing fact.
        public let time: Date?
        /// Remote address, rendered from `ut_addr_v6`. IPv4 when only the first
        /// word is set, IPv6 otherwise, nil when all-zero (a local login).
        public let address: String?
        /// Byte offset, so every record is citable at its exact location.
        public let fileOffset: Int
    }

    /// A login paired with its logout. This is DERIVED, not read: the file
    /// records two separate events and the pairing is an inference, so an
    /// unmatched login is reported as still-open rather than given a duration.
    public struct Session: Sendable, Equatable {
        public let user: String
        public let line: String
        public let host: String
        public let start: Date
        /// nil = no matching end record in this file. That is a real finding (the
        /// session was open when the log ended), not a missing value to paper over.
        public let end: Date?
        public let startOffset: Int
    }

    public enum ReaderError: Error, Sendable {
        /// The bytes are not a whole number of records, or neither byte order
        /// yields plausible ones.
        case notLoginRecords
        case empty
    }

    public nonisolated static let recordSize = 384

    // Field offsets inside one record.
    private nonisolated static let oType = 0, oPid = 4, oLine = 8, oID = 40,
                                   oUser = 44, oHost = 76, oSession = 336,
                                   oTimeSec = 340, oAddr = 348
    private nonisolated static let lineLength = 32, idLength = 4,
                                   userLength = 32, hostLength = 256

    /// Record ceiling. A long-lived server's `wtmp` can hold hundreds of
    /// thousands of logins; this is a citation surface, so it stops at a stated
    /// number rather than growing without bound.
    public nonisolated static let maxRecords = 200_000

    public let isBigEndian: Bool
    public let file: UtmpFile
    public private(set) var problems: [String] = []

    private let data: Data

    // MARK: - Init

    public init(data: Data, filename: String) throws {
        guard !data.isEmpty else { throw ReaderError.empty }
        self.file = UtmpFile.classify(filename: filename) ?? .loginHistory
        self.data = data

        // Choose the byte order by evidence rather than by assumption.
        let little = Self.plausibility(of: data, bigEndian: false)
        let big = Self.plausibility(of: data, bigEndian: true)
        guard max(little, big) > 0 else { throw ReaderError.notLoginRecords }
        self.isBigEndian = big > little

        if data.count % Self.recordSize != 0 {
            let extra = data.count % Self.recordSize
            problems.append("The file is not a whole number of \(Self.recordSize)-byte records: "
                            + "\(extra) trailing byte(s) were not read. That is what a copy "
                            + "taken while the file was being written looks like.")
        }
        if UtmpFile.classify(filename: filename) == nil {
            problems.append("The filename \"\((filename as NSString).lastPathComponent)\" is not "
                            + "utmp/wtmp/btmp, so which KIND of accounting file this is cannot be "
                            + "read from the name. It is reported as login history; if it is "
                            + "actually btmp, these are failed attempts rather than logins.")
        }
        if isBigEndian {
            problems.append("The records read as big-endian, so the machine was a big-endian "
                            + "architecture (s390x, older PowerPC/SPARC) rather than x86/ARM.")
        }
    }

    /// How well `data` reads as login records under one byte order. Scored rather
    /// than decided on the first record, because the first slot of a live `utmp`
    /// is routinely an empty or init record.
    private nonisolated static func plausibility(of data: Data, bigEndian: Bool) -> Int {
        let count = min(16, data.count / recordSize)
        guard count > 0 else { return 0 }
        var score = 0
        for index in 0..<count {
            let base = index * recordSize
            guard let rawType = i16(data, base + oType, bigEndian) else { return 0 }
            // A type outside the defined range means this reading is wrong.
            guard Kind(rawValue: rawType) != nil else { return 0 }
            score += 1
            if let seconds = i32(data, base + oTimeSec, bigEndian) {
                // 1990 … 2038 (the format's own ceiling).
                if seconds > 631_152_000, seconds < 2_147_483_647 { score += 2 }
                else if seconds != 0 { return 0 }   // a nonsense date means wrong order
            }
        }
        return score
    }

    /// Whether these bytes look like login accounting at all. Used only to
    /// classify a file that would OTHERWISE be dropped as unknown: the format has
    /// no magic signature, so this is a structural guess, and it is deliberately
    /// strict — every record in the sample must decode, and at least one must be a
    /// real dated session or boot.
    public nonisolated static func looksLikeLoginRecords(_ data: Data) -> Bool {
        guard data.count >= recordSize * 2 else { return false }
        for bigEndian in [false, true] {
            guard plausibility(of: data, bigEndian: bigEndian) > 0 else { continue }
            let count = min(16, data.count / recordSize)
            let hasRealEvent = (0..<count).contains { index in
                let base = index * recordSize
                guard let rawType = i16(data, base + oType, bigEndian),
                      let kind = Kind(rawValue: rawType),
                      let seconds = i32(data, base + oTimeSec, bigEndian), seconds > 0 else {
                    return false
                }
                switch kind {
                case .userProcess, .deadProcess, .bootTime, .runLevel, .loginProcess: return true
                default: return false
                }
            }
            if hasRealEvent { return true }
        }
        return false
    }

    // MARK: - Records

    public mutating func records() -> [Record] {
        var out: [Record] = []
        var offset = 0
        while offset + Self.recordSize <= data.count {
            defer { offset += Self.recordSize }
            guard let rawType = Self.i16(data, offset + Self.oType, isBigEndian),
                  let kind = Kind(rawValue: rawType) else {
                problems.append("The record at offset \(offset) has an unknown type; skipped.")
                continue
            }
            out.append(Record(
                kind: kind,
                pid: Self.i32(data, offset + Self.oPid, isBigEndian) ?? 0,
                line: Self.string(data, offset + Self.oLine, Self.lineLength),
                id: Self.string(data, offset + Self.oID, Self.idLength),
                user: Self.string(data, offset + Self.oUser, Self.userLength),
                host: Self.string(data, offset + Self.oHost, Self.hostLength),
                session: Self.i32(data, offset + Self.oSession, isBigEndian) ?? 0,
                time: Self.time(data, offset + Self.oTimeSec, isBigEndian),
                address: Self.address(data, offset + Self.oAddr, isBigEndian),
                fileOffset: offset))

            if out.count >= Self.maxRecords {
                problems.append("Stopped after \(Self.maxRecords) records; later records have no "
                                + "individual citation.")
                return out
            }
        }
        if out.isEmpty {
            problems.append("No readable records: the file has the right shape but every slot "
                            + "decoded as unusable.")
        }
        return out
    }

    /// Pair each login with the logout on the same terminal. INFERRED, and stated
    /// as such: `wtmp` stores two independent records and nothing links them but
    /// the tty, which is reused. Each login is matched with the FIRST later end
    /// record on its line, so a reused tty does not steal an earlier session's
    /// logout.
    public nonisolated static func sessions(from records: [Record]) -> [Session] {
        var open: [String: [(record: Record, index: Int)]] = [:]
        var pairedEnd: [Int: Date] = [:]

        for (index, record) in records.enumerated() {
            switch record.kind {
            case .userProcess where record.time != nil:
                open[record.line, default: []].append((record, index))
            case .deadProcess:
                // Close the OLDEST still-open session on this line: terminals are
                // recycled, and closing the newest would attribute one user's
                // logout to another user's session.
                guard var queue = open[record.line], !queue.isEmpty else { continue }
                let candidate = queue.removeFirst()
                open[record.line] = queue
                if let end = record.time { pairedEnd[candidate.index] = end }
            default:
                continue
            }
        }

        return records.enumerated().compactMap { index, record in
            guard record.kind == .userProcess, let start = record.time else { return nil }
            return Session(user: record.user, line: record.line, host: record.host,
                           start: start, end: pairedEnd[index], startOffset: record.fileOffset)
        }
    }

    // MARK: - Primitives (all bounds-checked)

    /// `ut_type` is a 16-bit `short` followed by two padding bytes. It MUST be read
    /// as 16 bits: reading four bytes happens to give the right answer
    /// little-endian (the padding lands in the high bytes) and gives `type << 16`
    /// big-endian, which would make every record look like an unknown type and
    /// silently defeat the byte-order probe.
    private nonisolated static func i16(_ d: Data, _ at: Int, _ bigEndian: Bool) -> Int32? {
        let i = d.startIndex + at
        guard at >= 0, i + 2 <= d.endIndex else { return nil }
        let value = bigEndian
            ? (UInt16(d[i]) << 8) | UInt16(d[i + 1])
            : (UInt16(d[i + 1]) << 8) | UInt16(d[i])
        return Int32(Int16(bitPattern: value))
    }

    private nonisolated static func i32(_ d: Data, _ at: Int, _ bigEndian: Bool) -> Int32? {
        let i = d.startIndex + at
        guard at >= 0, i + 4 <= d.endIndex else { return nil }
        let b = (UInt32(d[i]), UInt32(d[i + 1]), UInt32(d[i + 2]), UInt32(d[i + 3]))
        let value = bigEndian
            ? (b.0 << 24) | (b.1 << 16) | (b.2 << 8) | b.3
            : (b.3 << 24) | (b.2 << 16) | (b.1 << 8) | b.0
        return Int32(bitPattern: value)
    }

    /// A fixed-width C string. NUL-terminated, but a field filled to capacity is
    /// NOT terminated, so the width is the other bound. Non-printable bytes end
    /// the string rather than arriving as control characters in an answer.
    private nonisolated static func string(_ d: Data, _ at: Int, _ width: Int) -> String {
        let start = d.startIndex + at
        guard at >= 0, start + width <= d.endIndex else { return "" }
        var bytes: [UInt8] = []
        for i in 0..<width {
            let byte = d[start + i]
            if byte == 0 || byte < 0x20 || byte == 0x7F { break }
            bytes.append(byte)
        }
        guard !bytes.isEmpty else { return "" }
        // UTF-8 where valid; an account name is ASCII in practice, and Latin-1 is
        // the honest reading of the leftovers rather than dropping the field.
        return String(bytes: bytes, encoding: .utf8)
            ?? String(bytes.map { Character(UnicodeScalar($0)) })
    }

    /// `tv_sec` → Date. Zero means "not set", which is a real state for an empty
    /// slot and must not become 1970.
    private nonisolated static func time(_ d: Data, _ at: Int, _ bigEndian: Bool) -> Date? {
        guard let seconds = i32(d, at, bigEndian), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds))
    }

    /// `ut_addr_v6` → a readable address. Four 32-bit words: only the first set
    /// means IPv4; all four means IPv6; all zero means the login was local.
    private nonisolated static func address(_ d: Data, _ at: Int, _ bigEndian: Bool) -> String? {
        var words: [UInt32] = []
        for index in 0..<4 {
            guard let word = i32(d, at + index * 4, bigEndian) else { return nil }
            words.append(UInt32(bitPattern: word))
        }
        guard words.contains(where: { $0 != 0 }) else { return nil }

        // The address bytes are stored in network order regardless of the host's
        // integer order, so they are read as bytes, not as a swapped number.
        func bytes(_ index: Int) -> [UInt8] {
            let start = d.startIndex + at + index * 4
            guard start + 4 <= d.endIndex else { return [] }
            return (0..<4).map { d[start + $0] }
        }

        if words[1] == 0, words[2] == 0, words[3] == 0 {
            let b = bytes(0)
            guard b.count == 4 else { return nil }
            return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
        }
        let all = (0..<4).flatMap(bytes)
        guard all.count == 16 else { return nil }
        return stride(from: 0, to: 16, by: 2)
            .map { String(format: "%02x%02x", all[$0], all[$0 + 1]) }
            .joined(separator: ":")
    }
}
