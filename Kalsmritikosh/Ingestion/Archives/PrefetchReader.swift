//
//  PrefetchReader.swift
//  Kalsmritikosh
//
//  HOST-6d — reader for Windows Prefetch (`*.pf`). Pure Swift, read-only.
//
//  Prefetch is the artifact that answers "was this program RUN", which nothing
//  else in this lane does: Amcache proves a file was PRESENT, a shortcut proves
//  a file was pointed at, but a `.pf` file exists because Windows observed the
//  executable EXECUTE. It records the program name, a hash of the path it ran
//  from, a run COUNT, and the last run time — up to eight of them on Windows 8
//  and later, which gives a short execution history rather than a single point.
//
//  CORRECTING AN EARLIER, TOO-BROAD CALL. I previously set Prefetch aside whole
//  on the grounds that Windows 10+ compresses the file with LZXPRESS Huffman
//  and a decompressor could not be verified without a real sample. That was
//  right about the COMPRESSION and wrong about the format: the record layout
//  underneath is fixed-offset and version-tagged, and the Windows 7/8 files
//  (versions 17, 23, 26) are not compressed at all. So the uncompressed
//  generations are exactly as verifiable as `$MFT` or a shell link, and they
//  ship here.
//
//  Layout, by version (all little-endian):
//    0x00 version    u32   17 = Win XP/2003, 23 = Vista/7, 26 = Win 8.x,
//                          30 = Win 10/11 (only reachable once decompressed)
//    0x04 signature  "SCCA"
//    0x0C file size  u32
//    0x10 name       UTF-16, 60 chars, NUL-padded — the executable
//    0x4C path hash  u32   Windows's own hash of the full run path
//    then a version-specific information block holding the run times and count:
//      v17: last run FILETIME at 0x78, run count at 0x90
//      v23: last run FILETIME at 0x80, run count at 0x98
//      v26: EIGHT FILETIMEs from 0x80, run count at 0xD0
//
//  MAM-COMPRESSED FILES ARE REFUSED, NOT GUESSED. A Win10+ `.pf` begins with
//  "MAM\x04" and an uncompressed-size field. Decompressing it needs LZXPRESS
//  Huffman, which cannot be verified here without a real sample to check
//  against — a fixture produced by an encoder written to my own reading of the
//  spec would let a shared misunderstanding pass its own test. So a compressed
//  file is reported as present-and-not-decompressed, with its declared
//  uncompressed size, rather than being half-read.
//

import Foundation

public struct PrefetchReader: Sendable {

    /// The generations this reader decodes. Windows 10's version 30 is listed
    /// because it is what sits INSIDE a MAM container; it is only reachable
    /// once decompressed, which this reader does not do.
    public enum Version: UInt32, Sendable {
        case winXP = 17
        case winVista7 = 23
        case win8 = 26
        case win10 = 30

        public var label: String {
            switch self {
            case .winXP: return "Windows XP/2003"
            case .winVista7: return "Windows Vista/7"
            case .win8: return "Windows 8.x"
            case .win10: return "Windows 10/11"
            }
        }

        /// Offset of the first run FILETIME, and how many the format stores.
        var runTimes: (offset: Int, count: Int)? {
            switch self {
            case .winXP: return (0x78, 1)
            case .winVista7: return (0x80, 1)
            case .win8: return (0x80, 8)
            // v30's information block moved again; not decoded because a v30
            // file is only reachable through decompression this reader refuses.
            case .win10: return nil
            }
        }

        var runCountOffset: Int? {
            switch self {
            case .winXP: return 0x90
            case .winVista7: return 0x98
            case .win8: return 0xD0
            case .win10: return nil
            }
        }
    }

    public enum ReaderError: Error, Sendable {
        case notPrefetch
        case truncated
        /// A Windows 10+ file whose body is LZXPRESS-Huffman compressed.
        /// Carries the declared uncompressed size so the caller can say what
        /// was found without decoding it.
        case compressed(uncompressedSize: Int)
        /// The version tag is not one this reader decodes.
        case unsupportedVersion(UInt32)
    }

    public let version: Version
    /// The executable Windows observed running, e.g. `POWERSHELL.EXE`.
    public let executableName: String
    /// Windows's own hash of the full path the program ran from. Two entries
    /// for the same name with different hashes are the same program run from
    /// DIFFERENT locations, which is often the finding.
    public let pathHash: UInt32
    /// Run times, newest first as the format stores them. Zero entries are
    /// dropped — a v26 file with three runs pads the rest with zeros, and a
    /// padded slot is not a run that happened in 1601.
    public let runTimes: [Date]
    /// How many times Windows has seen this program execute.
    public let runCount: UInt32
    public private(set) var problems: [String] = []

    nonisolated static let signature = Data("SCCA".utf8)
    /// A Windows 10+ compressed container: "MAM" then the compression variant.
    nonisolated static let mamSignature = Data([0x4D, 0x41, 0x4D])
    nonisolated static let nameOffset = 0x10
    nonisolated static let nameCharacters = 60
    nonisolated static let pathHashOffset = 0x4C

    // MARK: - Init

    public init(data: Data) throws {
        guard data.count >= 4 else { throw ReaderError.truncated }

        // A compressed file is refused with its declared size, not half-read.
        if data.prefix(3) == Self.mamSignature {
            let declared = Self.u32(data, 4).map(Int.init) ?? 0
            throw ReaderError.compressed(uncompressedSize: declared)
        }

        guard data.count >= 0x10 else { throw ReaderError.truncated }
        guard data.subdata(in: 4..<8) == Self.signature else { throw ReaderError.notPrefetch }
        guard let rawVersion = Self.u32(data, 0) else { throw ReaderError.truncated }
        guard let version = Version(rawValue: rawVersion) else {
            throw ReaderError.unsupportedVersion(rawVersion)
        }
        guard version != .win10 else {
            // An uncompressed v30 is not something this reader has ever been
            // able to check against a real file, so it is declined rather than
            // decoded at offsets that may not hold.
            throw ReaderError.unsupportedVersion(rawVersion)
        }
        self.version = version

        guard let name = Self.utf16Name(data, at: Self.nameOffset,
                                        characters: Self.nameCharacters) else {
            throw ReaderError.truncated
        }
        self.executableName = name
        self.pathHash = Self.u32(data, Self.pathHashOffset) ?? 0

        var problems: [String] = []
        var times: [Date] = []
        if let spec = version.runTimes {
            for index in 0..<spec.count {
                let at = spec.offset + index * 8
                guard at + 8 <= data.count else {
                    problems.append("The run-time table is cut short: \(spec.count) slot(s) "
                                    + "expected, \(index) readable.")
                    break
                }
                // A zero slot is padding, not a run in 1601.
                if let date = Self.filetime(data, at) { times.append(date) }
            }
        }
        self.runTimes = times

        var count: UInt32 = 0
        if let at = version.runCountOffset, let value = Self.u32(data, at) {
            count = value
        } else {
            problems.append("The run count could not be read from this \(version.label) file.")
        }
        self.runCount = count

        if times.isEmpty {
            problems.append("No run time was recorded in this file, so the execution cannot be "
                            + "placed on the timeline. The run count and executable name still "
                            + "establish that Windows observed it run.")
        }
        self.problems = problems
    }

    // MARK: - Primitives (all bounds-checked)

    /// A fixed-width UTF-16 name field, NUL-terminated or full-width.
    nonisolated static func utf16Name(_ d: Data, at offset: Int, characters: Int) -> String? {
        let byteCount = characters * 2
        guard offset >= 0, d.startIndex + offset + byteCount <= d.endIndex else { return nil }
        var units: [UInt16] = []
        for index in 0..<characters {
            let i = d.startIndex + offset + index * 2
            let unit = UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
            if unit == 0 { break }
            units.append(unit)
        }
        guard !units.isEmpty else { return nil }
        let name = String(decoding: units, as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private nonisolated static func u32(_ d: Data, _ at: Int) -> UInt32? {
        let i = d.startIndex + at
        guard at >= 0, i + 4 <= d.endIndex else { return nil }
        return UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }
    private nonisolated static func u64(_ d: Data, _ at: Int) -> UInt64? {
        guard let lo = u32(d, at), let hi = u32(d, at + 4) else { return nil }
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    /// FILETIME → Date. Zero means "not recorded" — for a v26 file that is an
    /// unused run slot — and must never become 1601.
    private nonisolated static func filetime(_ d: Data, _ at: Int) -> Date? {
        guard let ticks = u64(d, at), ticks > 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        guard seconds > -2_208_988_800, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
