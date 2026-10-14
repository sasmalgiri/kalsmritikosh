//
//  MailRecovery.swift
//  Kalsmritikosh
//
//  W4-3 — recognise deleted mail that a mail client left inside the mailbox
//  file (ported in spirit from mailin's RecoveryDetectors; native, no mailin
//  store). Pure functions over a message's headers, labels and folder path:
//
//    Thunderbird   X-Mozilla-Status bit 0x0008 = expunged, still in the mbox until compaction
//    Pine / mutt   X-Status containing "D"
//    Gmail Takeout X-Gmail-Labels containing Trash / Bin
//    Folder        the message sits in a Deleted Items / Trash / Bin folder
//
//  A recovered message is marked "recovered, partial" — never mixed with live
//  mail, never presented as the user's current mailbox.
//

import Foundation

nonisolated public struct RecoveryInfo: Sendable, Equatable {
    public enum State: String, Sendable { case unpurged, trashed, deletedFolder }
    public let state: State
    public let method: String
    public let evidence: String

    public var label: String {
        switch state {
        case .unpurged:      return "Deleted, still in the mailbox file"
        case .trashed:       return "In the trash"
        case .deletedFolder: return "In a deleted-items folder"
        }
    }
}

nonisolated public enum RecoveryDetector {
    public static let mozillaExpunged: UInt32 = 0x0008
    static let deletedFolderNames: Set<String> = ["deleted items", "deleted messages", "trash", "bin", "deleted"]

    /// Case-insensitive header lookup.
    public static func value(_ headers: [String: String], _ name: String) -> String? {
        if let v = headers[name] { return v }
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    /// Recovery state from headers, labels and the folder path the message came from; nil = live mail.
    public static func detect(headers: [String: String], folderPath: String? = nil) -> RecoveryInfo? {
        if let raw = value(headers, "X-Mozilla-Status"),
           let flags = UInt32(raw.trimmingCharacters(in: .whitespaces), radix: 16), flags & mozillaExpunged != 0 {
            return RecoveryInfo(state: .unpurged, method: "x-mozilla-status", evidence: "X-Mozilla-Status \(raw.trimmingCharacters(in: .whitespaces))")
        }
        if let raw = value(headers, "X-Status"), raw.uppercased().contains("D") {
            return RecoveryInfo(state: .unpurged, method: "x-status", evidence: "X-Status \(raw)")
        }
        if let labels = value(headers, "X-Gmail-Labels") {
            let parts = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if parts.contains("trash") || parts.contains("bin") {
                return RecoveryInfo(state: .trashed, method: "x-gmail-labels", evidence: "X-Gmail-Labels \(labels)")
            }
        }
        if let folderPath {
            let comps = folderPath.lowercased().split(separator: "/").map { String($0).replacingOccurrences(of: ".mbox", with: "") }
            if let hit = comps.first(where: { deletedFolderNames.contains($0) }) {
                return RecoveryInfo(state: .deletedFolder, method: "folder", evidence: "Folder “\(hit)”")
            }
        }
        return nil
    }
}
