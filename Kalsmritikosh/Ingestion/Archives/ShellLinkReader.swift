//
//  ShellLinkReader.swift
//  Kalsmritikosh
//
//  HOST-6a — reader for the Windows Shell Link format (`.lnk`). Pure Swift,
//  read-only, no dependency.
//
//  WHY THIS FILE MATTERS MORE THAN IT LOOKS. A shortcut in `Recent`,
//  `Office/Recent` or on a desktop records the file it pointed AT: the full
//  original path, the size, the volume's serial number and label, and what kind
//  of drive it was — including REMOVABLE. So a `.lnk` is often the only
//  surviving evidence that a particular file existed on a particular USB stick
//  and was opened on this machine. The target itself is routinely gone; the link
//  remains.
//
//  Layout (Microsoft's MS-SHLLINK, fixed offsets):
//    - 76-byte header: size 0x4C, the link CLSID, flags, target file attributes,
//      the target's creation / access / write FILETIMEs, size, show command.
//    - optional LinkTargetIDList (shell item ids) — SKIPPED, see below.
//    - optional LinkInfo: volume id (drive type, serial, label) + local base
//      path, or a network share's name and device.
//    - StringData: name, relative path, working directory, command-line
//      arguments, icon location — present only as the flags say, in a fixed
//      order, ANSI or UTF-16 depending on one flag.
//    - ExtraData blocks, each size + signature. The TrackerDataBlock carries the
//      NetBIOS name of the machine that created the link.
//
//  TWO MISREADINGS THIS READER REFUSES TO ENABLE:
//
//  1. The three FILETIMEs describe the TARGET FILE, as it was when the shortcut
//     was last written — they are NOT when the shortcut was used. Reporting them
//     as "opened at" would date an access that this file does not record. The
//     parser labels them as the target's times, explicitly.
//  2. The tracker block's droid identifiers can contain the MAC address of the
//     machine that created them, but only when the UUID is version 1 and its
//     node is a real unicast address. A version-4 UUID's "node" is random bytes,
//     and reporting those as a MAC address would manufacture a hardware
//     identifier that could be attributed to a person. Both conditions are
//     checked; otherwise no address is reported at all.
//
//  The LinkTargetIDList is deliberately not decoded: shell item ids are a
//  loosely-documented, per-shell-folder tagged format, and the path information
//  worth having is carried in LinkInfo and RelativePath, which are fixed-offset
//  and verifiable. Its presence and size are still reported.
//

import Foundation

public struct ShellLinkReader: Sendable {

    /// What kind of volume the target lived on. `removable` is the forensically
    /// load-bearing one: it says the file came from a device that is not the
    /// machine's own disk.
    public enum DriveType: UInt32, Sendable {
        case unknown = 0, noRootDirectory = 1, removable = 2, fixed = 3
        case remote = 4, cdrom = 5, ramdisk = 6

        public var label: String {
            switch self {
            case .unknown: return "unknown"
            case .noRootDirectory: return "no root directory"
            case .removable: return "REMOVABLE (USB stick, memory card or floppy)"
            case .fixed: return "fixed disk"
            case .remote: return "network drive"
            case .cdrom: return "CD/DVD"
            case .ramdisk: return "RAM disk"
            }
        }
    }

    public struct Volume: Sendable, Equatable {
        public let driveType: DriveType
        /// The volume's serial number — the same volume on another machine still
        /// carries it, which is what links a file to a specific device.
        public let serialNumber: UInt32
        public let label: String?
    }

    public struct Tracker: Sendable, Equatable {
        /// NetBIOS name of the machine where the link was created.
        public let machineID: String
        /// MAC address of that machine's network adapter — present ONLY when the
        /// droid UUID is version 1 with a unicast node. nil is the honest answer
        /// in every other case.
        public let macAddress: String?
    }

    public enum ReaderError: Error, Sendable {
        case notAShellLink
        case truncated
    }

    public let targetCreated: Date?
    public let targetAccessed: Date?
    public let targetWritten: Date?
    public let targetSizeBytes: UInt32
    public let targetIsDirectory: Bool
    /// `C:\evidence\report.docx` — the target's path on the machine that made
    /// the link.
    public let localBasePath: String?
    /// `\\FILESERVER\cases` for a link to a share.
    public let networkPath: String?
    public let commonPathSuffix: String?
    public let volume: Volume?
    public let name: String?
    public let relativePath: String?
    public let workingDirectory: String?
    public let commandLineArguments: String?
    public let iconLocation: String?
    public let tracker: Tracker?
    /// Size of the shell-item id list, which is present but not decoded.
    public let targetIDListSize: Int?
    public private(set) var problems: [String] = []

    nonisolated static let headerSize: UInt32 = 0x4C
    /// 00021401-0000-0000-C000-000000000046, the shell link class id, stored as
    /// a little-endian GUID.
    nonisolated static let linkCLSID: [UInt8] = [
        0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46
    ]
    /// The 20 bytes that identify a `.lnk` whatever it was renamed to.
    public nonisolated static var signature: [UInt8] { [0x4C, 0x00, 0x00, 0x00] + linkCLSID }

    private nonisolated static let trackerSignature: UInt32 = 0xA000_0003

    // MARK: - Init

    public init(data: Data) throws {
        guard data.count >= 4 else { throw ReaderError.truncated }
        guard Self.u32(data, 0) == Self.headerSize else { throw ReaderError.notAShellLink }
        guard data.count >= Int(Self.headerSize) else { throw ReaderError.truncated }
        guard Array(data.subdata(in: 4..<20)) == Self.linkCLSID else { throw ReaderError.notAShellLink }

        let flags = Self.u32(data, 0x14) ?? 0
        let attributes = Self.u32(data, 0x18) ?? 0
        targetIsDirectory = (attributes & 0x0000_0010) != 0
        targetCreated = Self.filetime(data, 0x1C)
        targetAccessed = Self.filetime(data, 0x24)
        targetWritten = Self.filetime(data, 0x2C)
        targetSizeBytes = Self.u32(data, 0x34) ?? 0

        let isUnicode = (flags & Flag.isUnicode) != 0
        var offset = Int(Self.headerSize)
        var problems: [String] = []

        // LinkTargetIDList — size-prefixed and skipped by exactly that size.
        var idListSize: Int?
        if (flags & Flag.hasLinkTargetIDList) != 0 {
            if let size = Self.u16(data, offset).map(Int.init), offset + 2 + size <= data.count {
                idListSize = size
                offset += 2 + size
            } else {
                problems.append("The shortcut declares a shell-item id list that does not fit in "
                                + "the file; everything after it was not read.")
                self.targetIDListSize = nil
                self.localBasePath = nil; self.networkPath = nil; self.commonPathSuffix = nil
                self.volume = nil; self.name = nil; self.relativePath = nil
                self.workingDirectory = nil; self.commandLineArguments = nil
                self.iconLocation = nil; self.tracker = nil
                self.problems = problems
                return
            }
        }
        self.targetIDListSize = idListSize

        // LinkInfo — where the volume and the real path live.
        var localBasePath: String?
        var networkPath: String?
        var commonPathSuffix: String?
        var volume: Volume?
        if (flags & Flag.hasLinkInfo) != 0 {
            if let size = Self.u32(data, offset).map(Int.init), size >= 0x1C,
               offset + size <= data.count {
                let info = Self.parseLinkInfo(data, at: offset, size: size)
                localBasePath = info.localBasePath
                networkPath = info.networkPath
                commonPathSuffix = info.commonPathSuffix
                volume = info.volume
                problems += info.problems
                offset += size
            } else {
                problems.append("The shortcut's location information is truncated; the target "
                                + "path and volume could not be read.")
                offset = data.count
            }
        }
        self.localBasePath = localBasePath
        self.networkPath = networkPath
        self.commonPathSuffix = commonPathSuffix
        self.volume = volume

        // StringData — present only as the flags say, always in this order.
        func nextString(_ present: Bool) -> String? {
            guard present, offset < data.count else { return nil }
            guard let characters = Self.u16(data, offset).map(Int.init) else { return nil }
            offset += 2
            let byteCount = isUnicode ? characters * 2 : characters
            guard byteCount >= 0, offset + byteCount <= data.count else {
                offset = data.count
                return nil
            }
            let bytes = data.subdata(in: offset..<(offset + byteCount))
            offset += byteCount
            let text = isUnicode
                ? String(data: bytes, encoding: .utf16LittleEndian)
                : String(data: bytes, encoding: .windowsCP1252)
            guard let text, !text.isEmpty else { return nil }
            return text
        }
        self.name = nextString((flags & Flag.hasName) != 0)
        self.relativePath = nextString((flags & Flag.hasRelativePath) != 0)
        self.workingDirectory = nextString((flags & Flag.hasWorkingDir) != 0)
        self.commandLineArguments = nextString((flags & Flag.hasArguments) != 0)
        self.iconLocation = nextString((flags & Flag.hasIconLocation) != 0)

        // ExtraData — a chain of size/signature blocks; the tracker is the one
        // that names the machine.
        var tracker: Tracker?
        while offset + 8 <= data.count {
            guard let blockSize = Self.u32(data, offset).map(Int.init), blockSize >= 0x04 else { break }
            guard blockSize >= 8, offset + blockSize <= data.count else {
                problems.append("An extra-data block at offset \(offset) declares \(blockSize) "
                                + "bytes, which does not fit in the file; it was not read.")
                break
            }
            if Self.u32(data, offset + 4) == Self.trackerSignature {
                tracker = Self.parseTracker(data, at: offset, size: blockSize)
            }
            offset += blockSize
        }
        self.tracker = tracker
        self.problems = problems
    }

    /// Whether the target's own path was recovered at all — a link with neither
    /// a local nor a network path tells you nothing about WHAT it pointed to.
    public var targetPath: String? {
        if let base = localBasePath {
            guard let suffix = commonPathSuffix, !suffix.isEmpty else { return base }
            return base.hasSuffix("\\") ? base + suffix : base + "\\" + suffix
        }
        if let network = networkPath {
            guard let suffix = commonPathSuffix, !suffix.isEmpty else { return network }
            return network + "\\" + suffix
        }
        return nil
    }

    // MARK: - LinkFlags

    private enum Flag {
        static let hasLinkTargetIDList: UInt32 = 1 << 0
        static let hasLinkInfo: UInt32 = 1 << 1
        static let hasName: UInt32 = 1 << 2
        static let hasRelativePath: UInt32 = 1 << 3
        static let hasWorkingDir: UInt32 = 1 << 4
        static let hasArguments: UInt32 = 1 << 5
        static let hasIconLocation: UInt32 = 1 << 6
        static let isUnicode: UInt32 = 1 << 7
    }

    // MARK: - LinkInfo

    private struct LinkInfo {
        var localBasePath: String?
        var networkPath: String?
        var commonPathSuffix: String?
        var volume: Volume?
        var problems: [String] = []
    }

    private nonisolated static func parseLinkInfo(_ d: Data, at base: Int, size: Int) -> LinkInfo {
        var out = LinkInfo()
        let headerSize = Int(u32(d, base + 0x04) ?? 0)
        let infoFlags = u32(d, base + 0x08) ?? 0
        let volumeIDOffset = Int(u32(d, base + 0x0C) ?? 0)
        let localBasePathOffset = Int(u32(d, base + 0x10) ?? 0)
        let networkRelativeOffset = Int(u32(d, base + 0x14) ?? 0)
        let commonSuffixOffset = Int(u32(d, base + 0x18) ?? 0)
        // A header of 0x24 or more carries UNICODE variants of the two path
        // offsets. They win when present: the ANSI copy of a path with non-Latin
        // characters is lossy, and a path is what identifies the file.
        let hasUnicodeOffsets = headerSize >= 0x24
        let localUnicodeOffset = hasUnicodeOffsets ? Int(u32(d, base + 0x1C) ?? 0) : 0
        let suffixUnicodeOffset = hasUnicodeOffsets ? Int(u32(d, base + 0x20) ?? 0) : 0

        func ansi(_ relative: Int) -> String? {
            guard relative > 0 else { return nil }
            return cString(d, at: base + relative, limit: base + size)
        }
        func unicode(_ relative: Int) -> String? {
            guard relative > 0 else { return nil }
            return wideCString(d, at: base + relative, limit: base + size)
        }

        if (infoFlags & 0x01) != 0 {      // VolumeIDAndLocalBasePath
            out.localBasePath = unicode(localUnicodeOffset) ?? ansi(localBasePathOffset)
            if volumeIDOffset > 0, volumeIDOffset + 16 <= size {
                let v = base + volumeIDOffset
                let rawType = u32(d, v + 0x04) ?? 0
                let labelOffset = Int(u32(d, v + 0x0C) ?? 0)
                var label: String?
                if labelOffset == 0x14 {
                    // The sentinel says the label is UNICODE at its own offset.
                    let unicodeLabelOffset = Int(u32(d, v + 0x10) ?? 0)
                    if unicodeLabelOffset > 0 {
                        label = wideCString(d, at: v + unicodeLabelOffset, limit: base + size)
                    }
                } else if labelOffset > 0 {
                    label = cString(d, at: v + labelOffset, limit: base + size)
                }
                out.volume = Volume(
                    driveType: DriveType(rawValue: rawType) ?? .unknown,
                    serialNumber: u32(d, v + 0x08) ?? 0,
                    label: label?.isEmpty == false ? label : nil)
            }
        }
        if (infoFlags & 0x02) != 0 {      // CommonNetworkRelativeLinkAndPathSuffix
            if networkRelativeOffset > 0, networkRelativeOffset + 20 <= size {
                let n = base + networkRelativeOffset
                let netNameOffset = Int(u32(d, n + 0x08) ?? 0)
                if netNameOffset > 0 {
                    out.networkPath = cString(d, at: n + netNameOffset, limit: base + size)
                }
            }
            out.commonPathSuffix = unicode(suffixUnicodeOffset) ?? ansi(commonSuffixOffset)
        } else if out.localBasePath != nil {
            out.commonPathSuffix = unicode(suffixUnicodeOffset) ?? ansi(commonSuffixOffset)
        }
        return out
    }

    // MARK: - TrackerDataBlock

    private nonisolated static func parseTracker(_ d: Data, at base: Int, size: Int) -> Tracker? {
        // size(4) signature(4) length(4) version(4) machineID(16) droids(32)
        guard size >= 0x60 else { return nil }
        let machineBytes = (0..<16).compactMap { index -> UInt8? in
            let i = d.startIndex + base + 0x10 + index
            return i < d.endIndex ? d[i] : nil
        }
        let machineID = String(decoding: machineBytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !machineID.isEmpty else { return nil }

        // The block carries FOUR GUIDs, which is why it is 0x60 bytes and not
        // 0x40: Droid (volume 0x20, object 0x30) and DroidBirth (volume 0x40,
        // object 0x50). The OBJECT ids are the ones generated on the machine, so
        // they are the ones that can carry a MAC. The BIRTH object id is
        // preferred: it is written when the file is first tracked and survives
        // later moves, while Droid is rewritten.
        let birthObject = macAddress(inUUIDAt: base + 0x50, d)
        let droidObject = macAddress(inUUIDAt: base + 0x30, d)
        return Tracker(machineID: machineID, macAddress: birthObject ?? droidObject)
    }

    /// A version-1 UUID's last six bytes ARE the creating machine's MAC address.
    /// Anything else's are not, and reporting them as one would manufacture a
    /// hardware identifier that an investigation could attribute to a person. So
    /// three things are required: the bytes are present, the version nibble is 1,
    /// and the node is unicast (a random node sets the multicast bit precisely to
    /// mark itself as not a real address).
    nonisolated static func macAddress(inUUIDAt offset: Int, _ d: Data) -> String? {
        guard offset >= 0, d.startIndex + offset + 16 <= d.endIndex else { return nil }
        let bytes = (0..<16).map { d[d.startIndex + offset + $0] }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        // time_hi_and_version: the version is the high nibble of byte 7.
        guard (bytes[7] >> 4) == 1 else { return nil }
        let node = Array(bytes[10..<16])
        guard (node[0] & 0x01) == 0 else { return nil }   // multicast bit ⇒ not a real MAC
        guard node.contains(where: { $0 != 0 }) else { return nil }
        return node.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: - Primitives (all bounds-checked)

    private nonisolated static func u16(_ d: Data, _ at: Int) -> UInt16? {
        let i = d.startIndex + at
        guard at >= 0, i + 2 <= d.endIndex else { return nil }
        return UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
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

    /// FILETIME → Date. Zero means "not recorded", which is a real state for a
    /// shortcut whose target had no such time, and must never become 1601.
    private nonisolated static func filetime(_ d: Data, _ at: Int) -> Date? {
        guard let ticks = u64(d, at), ticks > 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        guard seconds > -2_208_988_800, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private nonisolated static func cString(_ d: Data, at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < limit else { return nil }
        var bytes: [UInt8] = []
        var i = offset
        while i < min(limit, d.count) {
            let byte = d[d.startIndex + i]
            if byte == 0 { break }
            bytes.append(byte)
            i += 1
        }
        guard !bytes.isEmpty else { return nil }
        return String(data: Data(bytes), encoding: .windowsCP1252)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    private nonisolated static func wideCString(_ d: Data, at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset + 1 < limit else { return nil }
        var units: [UInt16] = []
        var i = offset
        while i + 1 < min(limit, d.count) {
            let unit = UInt16(d[d.startIndex + i]) | (UInt16(d[d.startIndex + i + 1]) << 8)
            if unit == 0 { break }
            units.append(unit)
            i += 2
        }
        guard !units.isEmpty else { return nil }
        return String(decoding: units, as: UTF16.self)
    }
}
