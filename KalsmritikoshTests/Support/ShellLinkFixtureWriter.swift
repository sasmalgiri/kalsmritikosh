//
//  ShellLinkFixtureWriter.swift
//  KalsmritikoshTests
//
//  HOST-6a test support — writes real Windows shortcuts.
//
//  Built by laying each field at its documented MS-SHLLINK offset and computing
//  the LinkInfo internal offsets from the sizes of what was written, which is
//  how Windows itself produces them. It is independent of how ShellLinkReader
//  walks the file, so agreement between the two is evidence rather than
//  coincidence.
//

import Foundation
@testable import Kalsmritikosh

struct ShellLinkFixtureWriter {

    struct Volume {
        var driveType: UInt32 = 3           // fixed disk
        var serialNumber: UInt32 = 0
        var label: String = ""
    }

    struct Tracker {
        var machineID: String
        /// Written into the file droid as a version-1 UUID's node, which is
        /// where a real MAC address lives.
        var macAddress: [UInt8]?
        /// Force a version-4 UUID instead, whose node bytes are random and must
        /// NOT be reported as a hardware address.
        var useVersion4 = false
        /// Set the multicast bit, which marks a node as not a real address.
        var multicastNode = false
    }

    var targetCreated: Date?
    var targetAccessed: Date?
    var targetWritten: Date?
    var targetSizeBytes: UInt32 = 0
    var targetIsDirectory = false

    var localBasePath: String?
    var commonPathSuffix: String?
    var networkPath: String?
    var volume: Volume?

    var name: String?
    var relativePath: String?
    var workingDirectory: String?
    var arguments: String?
    var iconLocation: String?

    var tracker: Tracker?
    /// Bytes of a declared-but-not-decoded shell-item id list.
    var targetIDListBytes = 0
    /// Write the string fields as UTF-16 (the IsUnicode flag) rather than ANSI.
    var unicodeStrings = true

    func build() -> Data {
        var flags: UInt32 = 0
        if targetIDListBytes > 0 { flags |= 1 << 0 }
        if localBasePath != nil || networkPath != nil { flags |= 1 << 1 }
        if name != nil { flags |= 1 << 2 }
        if relativePath != nil { flags |= 1 << 3 }
        if workingDirectory != nil { flags |= 1 << 4 }
        if arguments != nil { flags |= 1 << 5 }
        if iconLocation != nil { flags |= 1 << 6 }
        if unicodeStrings { flags |= 1 << 7 }

        var out = Data()
        out += Self.u32(0x4C)                                   // 0x00 header size
        out += Data(ShellLinkReader.linkCLSID)                  // 0x04 link CLSID
        out += Self.u32(flags)                                  // 0x14 link flags
        out += Self.u32(targetIsDirectory ? 0x10 : 0x20)        // 0x18 file attributes
        out += Self.filetime(targetCreated)                     // 0x1C
        out += Self.filetime(targetAccessed)                    // 0x24
        out += Self.filetime(targetWritten)                     // 0x2C
        out += Self.u32(targetSizeBytes)                        // 0x34
        out += Self.u32(0)                                      // 0x38 icon index
        out += Self.u32(1)                                      // 0x3C show command
        out += Self.u16(0)                                      // 0x40 hotkey
        out += Self.u16(0)                                      // 0x42 reserved1
        out += Self.u32(0)                                      // 0x44 reserved2
        out += Self.u32(0)                                      // 0x48 reserved3
        precondition(out.count == 0x4C)

        if targetIDListBytes > 0 {
            out += Self.u16(UInt16(targetIDListBytes))
            out += Data((0..<targetIDListBytes).map { UInt8(($0 * 7 + 3) % 251) })
        }
        if localBasePath != nil || networkPath != nil { out += linkInfo() }

        func string(_ text: String?) {
            guard let text else { return }
            if unicodeStrings {
                let units = Array(text.utf16)
                out += Self.u16(UInt16(units.count))
                for unit in units { out += Self.u16(unit) }
            } else {
                let bytes = Array(text.utf8)
                out += Self.u16(UInt16(bytes.count))
                out += Data(bytes)
            }
        }
        string(name)
        string(relativePath)
        string(workingDirectory)
        string(arguments)
        string(iconLocation)

        if let tracker { out += trackerBlock(tracker) }
        out += Self.u32(0)      // terminal block: size < 4 ends the extra-data chain
        return out
    }

    // MARK: - LinkInfo

    private func linkInfo() -> Data {
        // Layout: a 0x1C header, then (optionally) a VolumeID + local base path,
        // then (optionally) a network relative link, then the common suffix.
        // Every internal offset is measured from the start of LinkInfo.
        var infoFlags: UInt32 = 0
        if localBasePath != nil { infoFlags |= 0x01 }
        if networkPath != nil { infoFlags |= 0x02 }

        let headerSize = 0x1C
        var body = Data()                       // everything after the header
        var volumeIDOffset: UInt32 = 0
        var localBasePathOffset: UInt32 = 0
        var networkOffset: UInt32 = 0
        var suffixOffset: UInt32 = 0

        if let localBasePath {
            let v = volume ?? Volume()
            volumeIDOffset = UInt32(headerSize + body.count)
            var volumeID = Data()
            let labelBytes = Array(v.label.utf8) + [0]
            volumeID += Self.u32(UInt32(16 + labelBytes.count))   // VolumeID size
            volumeID += Self.u32(v.driveType)
            volumeID += Self.u32(v.serialNumber)
            volumeID += Self.u32(0x10)                            // label offset
            volumeID += Data(labelBytes)
            body += volumeID

            localBasePathOffset = UInt32(headerSize + body.count)
            body += Data(Array(localBasePath.utf8) + [0])
        }
        if let networkPath {
            networkOffset = UInt32(headerSize + body.count)
            var network = Data()
            let nameBytes = Array(networkPath.utf8) + [0]
            network += Self.u32(UInt32(20 + nameBytes.count))     // size
            network += Self.u32(0)                                // flags
            network += Self.u32(20)                               // net name offset
            network += Self.u32(0)                                // device name offset
            network += Self.u32(0)                                // provider type
            network += Data(nameBytes)
            body += network
        }
        suffixOffset = UInt32(headerSize + body.count)
        body += Data(Array((commonPathSuffix ?? "").utf8) + [0])

        var out = Data()
        out += Self.u32(UInt32(headerSize + body.count))          // LinkInfoSize
        out += Self.u32(UInt32(headerSize))                       // LinkInfoHeaderSize
        out += Self.u32(infoFlags)
        out += Self.u32(volumeIDOffset)
        out += Self.u32(localBasePathOffset)
        out += Self.u32(networkOffset)
        out += Self.u32(suffixOffset)
        precondition(out.count == headerSize)
        return out + body
    }

    // MARK: - TrackerDataBlock

    private func trackerBlock(_ tracker: Tracker) -> Data {
        var out = Data()
        out += Self.u32(0x60)                   // block size
        out += Self.u32(0xA000_0003)            // TrackerDataBlock signature
        out += Self.u32(0x58)                   // length
        out += Self.u32(0)                      // version
        var machine = Array(tracker.machineID.utf8.prefix(16))
        machine += [UInt8](repeating: 0, count: 16 - machine.count)
        out += Data(machine)                    // 0x10 machine id

        // A TrackerDataBlock is 0x60 bytes because it carries FOUR GUIDs, not
        // two: Droid (volume + object) and DroidBirth (birth volume + birth
        // object). Writing only two makes the block declare 96 bytes with 64
        // present, which a reader must refuse.
        out += Data(repeating: 0xAB, count: 16) // 0x20 Droid.VolumeID
        out += Data(objectDroid(tracker))       // 0x30 Droid.ObjectID — MAC carrier
        out += Data(repeating: 0xCD, count: 16) // 0x40 DroidBirth.VolumeID
        out += Data(objectDroid(tracker))       // 0x50 DroidBirth.ObjectID — MAC carrier
        precondition(out.count == 0x60)
        return out
    }

    /// A UUID whose node field is the MAC address, in the layout the reader
    /// checks: version nibble in the high half of byte 7, node in bytes 10…15.
    private func objectDroid(_ tracker: Tracker) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x11, count: 16)
        let version: UInt8 = tracker.useVersion4 ? 4 : 1
        bytes[7] = (version << 4) | 0x0A
        if var mac = tracker.macAddress, mac.count == 6 {
            if tracker.multicastNode { mac[0] |= 0x01 } else { mac[0] &= 0xFE }
            for (index, byte) in mac.enumerated() { bytes[10 + index] = byte }
        }
        return bytes
    }

    // MARK: - Primitives

    private static func u16(_ v: UInt16) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func u32(_ v: UInt32) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func filetime(_ date: Date?) -> Data {
        guard let date else { return Data(repeating: 0, count: 8) }
        let ticks = UInt64((date.timeIntervalSince1970 + 11_644_473_600.0) * 10_000_000.0)
        var le = ticks.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
}
