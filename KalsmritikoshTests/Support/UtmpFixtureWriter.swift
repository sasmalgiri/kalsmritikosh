//
//  UtmpFixtureWriter.swift
//  KalsmritikoshTests
//
//  HOST-4 test support — writes real Linux login-accounting files.
//
//  Built from the published `struct utmp` layout by placing each field at its
//  documented offset, independently of how the reader walks it. Both byte orders
//  can be produced, which is what lets the reader's byte-order probe be tested
//  rather than assumed.
//

import Foundation
@testable import Kalsmritikosh

struct UtmpFixtureWriter {

    struct Record {
        var kind: UtmpReader.Kind
        var pid: Int32 = 0
        var line: String = ""
        var id: String = ""
        var user: String = ""
        var host: String = ""
        var time: Date?
        /// Written into `ut_addr_v6` as four network-order bytes.
        var ipv4: (UInt8, UInt8, UInt8, UInt8)?

        static func session(_ user: String, on line: String, at time: Date,
                            from host: String = "", pid: Int32 = 1000) -> Record {
            Record(kind: .userProcess, pid: pid, line: line, user: user, host: host, time: time)
        }
        static func ended(on line: String, at time: Date, user: String = "") -> Record {
            Record(kind: .deadProcess, line: line, user: user, time: time)
        }
        static func boot(at time: Date) -> Record {
            Record(kind: .bootTime, line: "~", user: "reboot", time: time)
        }
        static var emptySlot: Record { Record(kind: .empty) }
    }

    var bigEndian = false

    func build(records: [Record], trailingGarbage: Int = 0) -> Data {
        var out = Data()
        for record in records { out += encode(record) }
        if trailingGarbage > 0 {
            out += Data((0..<trailingGarbage).map { UInt8(($0 * 13 + 7) % 251) })
        }
        return out
    }

    // MARK: - One record

    private func encode(_ record: Record) -> Data {
        var bytes = [UInt8](repeating: 0, count: UtmpReader.recordSize)

        func put(_ value: Int16, at offset: Int) {
            let raw = UInt16(bitPattern: value)
            if bigEndian {
                bytes[offset] = UInt8(raw >> 8); bytes[offset + 1] = UInt8(raw & 0xFF)
            } else {
                bytes[offset] = UInt8(raw & 0xFF); bytes[offset + 1] = UInt8(raw >> 8)
            }
        }
        func put(_ value: Int32, at offset: Int) {
            let raw = UInt32(bitPattern: value)
            let order = bigEndian ? [24, 16, 8, 0] : [0, 8, 16, 24]
            for (index, shift) in order.enumerated() {
                bytes[offset + index] = UInt8((raw >> UInt32(shift)) & 0xFF)
            }
        }
        func put(_ text: String, at offset: Int, width: Int) {
            for (index, byte) in Array(text.utf8).prefix(width).enumerated() {
                bytes[offset + index] = byte
            }
        }

        put(Int16(record.kind.rawValue), at: 0)      // ut_type (+ 2 bytes padding)
        put(record.pid, at: 4)                       // ut_pid
        put(record.line, at: 8, width: 32)           // ut_line
        put(record.id, at: 40, width: 4)             // ut_id
        put(record.user, at: 44, width: 32)          // ut_user
        put(record.host, at: 76, width: 256)         // ut_host
        put(Int32(0), at: 336)                       // ut_session
        // ut_tv — two 32-bit values on every architecture, which is why these
        // files are portable across them.
        put(Int32(record.time.map { Int32($0.timeIntervalSince1970) } ?? 0), at: 340)
        put(Int32(0), at: 344)
        if let ipv4 = record.ipv4 {
            // ut_addr_v6 holds the address in NETWORK order regardless of the
            // host's integer order, so the octets are written as bytes.
            bytes[348] = ipv4.0; bytes[349] = ipv4.1
            bytes[350] = ipv4.2; bytes[351] = ipv4.3
        }
        return Data(bytes)
    }
}
