//
//  SafeFilename.swift
//  Kalsmritikosh
//
//  Smart-map IN-10 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04): a name taken from inside
//  supplied material (an email attachment's declared filename, a derived copy's name) becomes ONE path
//  component inside the app's own staging directory, never a path. Separators, NUL and control characters
//  are replaced, bidirectional-override characters (which can make "invoice‮fdp.exe" display as
//  "invoiceexe.pdf") are replaced visibly, leading dots cannot make a hidden or parent entry, and the result
//  fits the file system's 255-byte name limit with its extension kept — an over-long name used to make the
//  write fail and the attachment vanish.
//

import Foundation

public nonisolated enum SafeFilename {
    /// The file system's per-component byte limit (APFS / HFS+ NAME_MAX).
    public static let maxBytes = 255
    /// Room kept for the suffixes callers add (a short content hash, a counter).
    public static let reservedBytes = 32

    /// Characters that can never appear in a component: path separators, NUL, and characters Windows-authored
    /// archives and mail clients treat as reserved.
    static let reserved = CharacterSet(charactersIn: "/\\?%*|\"<>:\u{0}")
    /// Bidirectional controls that reorder how a name DISPLAYS (U+202A–U+202E, U+2066–U+2069, U+200E/F, U+061C).
    static let bidi: Set<Unicode.Scalar> = Set(
        ([0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C] as [UInt32])
            .compactMap { Unicode.Scalar($0) })

    /// One safe path component for `raw`, or `fallback` when nothing usable is left.
    public static func sanitize(_ raw: String, fallback: String = "attachment") -> String {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            if reserved.contains(s) || CharacterSet.controlCharacters.contains(s) || bidi.contains(s) {
                scalars.append("_")
            } else {
                scalars.append(s)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        // No hidden entry, no "." / ".." component: leading dots become underscores.
        while name.hasPrefix(".") { name = "_" + String(name.dropFirst()) }
        if name.isEmpty || name.allSatisfy({ $0 == "_" }) { name = fallback }
        return fit(name, maxBytes: maxBytes - reservedBytes)
    }

    /// Truncate to `maxBytes` UTF-8 bytes on a character boundary, keeping a short extension.
    static func fit(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let keepExt = !ext.isEmpty && ext.utf8.count <= 16
        let suffix = keepExt ? "." + ext : ""
        var stem = keepExt ? String(name.dropLast(suffix.count)) : name
        while !stem.isEmpty && stem.utf8.count + suffix.utf8.count > maxBytes { stem.removeLast() }
        return (stem.isEmpty ? "attachment" : stem) + suffix
    }
}
