//
//  EmailAddressHygiene.swift
//  Kalsmritikosh
//
//  Owner live-archive audit (2026-09-22/23). Two deterministic cleanups for
//  addresses harvested by the whole-document email regex, both driven by real
//  values found in the owner's ledger:
//
//  1. MACHINE-GENERATED addresses are not correspondents. Mail infrastructure
//     leaves Message-IDs, SMTP trace artifacts and inline-image content-IDs in
//     document text (quoted reply chains and PDF mail exports carry full
//     headers), and the regex can't tell them from a person:
//       4fa27c09.5c91cc0a.7f04.7fb6@mx.google.com
//       55df0168.0b8a420a.48ce7.ffffda74SMTPIN_ADDED_BROKEN@mx.google.com
//       CAPuxmJrhQe7SReGWdghBunk-kD_NBHxcqyD38ansEZAgMfG8Ag@mail.gmail.com
//       image001.png@01CE304B.FCDAA
//       d534ed66-15ba-46e3-9c95-31cf4805ea5e@gmail.com
//
//  2. TRUNCATED VARIANTS: one real address can appear alongside strict-suffix
//     fragments of itself when the source text wrapped it (PDF line-wrap, a
//     loader that didn't transfer-decode). The live ledger held SEVEN variants
//     of one address — sasmalgiri@gmail.com plus asmalgiri@, smalgiri@,
//     malgiri@, algiri@, lgiri@, iri@gmail.com. A fragment that is a strict
//     suffix of a longer address ON THE SAME DOMAIN is dropped.
//
//  Pure, deterministic, no allocation surprises — safe to run on every document.
//  Deliberately conservative: a short-but-real address (li@acme.com) survives
//  unless a longer address on that same domain ends with it.
//

import Foundation

public nonisolated enum EmailAddressHygiene {

    // MARK: - 1. Machine-generated addresses

    /// Domains that only ever appear in mail INFRASTRUCTURE headers, never as a
    /// human correspondent's address.
    private static let machineDomains: Set<String> = [
        "mx.google.com", "mail.gmail.com", "googlemail.com",
        "reply.facebook.com", "facebookmail.com", "profiles.google.com",
        "smtpnet.hathway.com", "hxcore.ol"
    ]

    /// Substrings that mark an SMTP/trace artifact wherever they appear.
    private static let traceMarkers = ["smtpin_added_broken", "mailer-daemon", "postmaster@"]

    /// File extensions that mark an inline-image / attachment content-ID
    /// (`image001.png@01CE304B.FCDAA`) rather than a mailbox.
    private static let contentIDExtensions = [
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".pdf", ".doc", ".docx"
    ]

    /// True when the address is mail plumbing rather than a person/org mailbox.
    ///
    /// CASE IS SIGNIFICANT: mixed case + digits is the signature of a generated
    /// token (`Nk+aNyumTTg5toXw`), so the shape heuristics run on the ORIGINAL
    /// local part. Only domain / marker / extension comparisons are lowercased.
    public static func isMachineGenerated(_ address: String) -> Bool {
        let lower = address.lowercased()
        for marker in traceMarkers where lower.contains(marker) { return true }

        guard let at = address.lastIndex(of: "@"),
              let lowerAt = lower.lastIndex(of: "@") else { return false }
        let local = String(address[address.startIndex..<at])          // case preserved
        let localLower = String(lower[lower.startIndex..<lowerAt])
        let domain = String(lower[lower.index(after: lowerAt)...])
        guard !local.isEmpty, !domain.isEmpty else { return true }

        // An inline-image content ID: the local part is a filename.
        for ext in contentIDExtensions where localLower.hasSuffix(ext) { return true }

        // A bare UUID local part is a generated identifier, never a mailbox.
        if isUUIDShaped(localLower) { return true }

        // A random-shaped token is plumbing on ANY domain once it's long enough
        // to not be a name (`Nk+aNyumTTg5toXw`, `CAPuxmJrhQe7...`).
        if local.count >= 16, hasRandomTokenShape(local) { return true }

        // On known infrastructure domains, only a plainly human-looking local
        // part survives (so a genuine person@googlemail.com is still kept).
        if machineDomains.contains(domain) {
            return hasRandomTokenShape(local) || !isHumanLooking(localLower)
        }

        // Message-ID shape on ANY domain: dot-separated hex groups, e.g.
        // `4fa27c09.5c91cc0a.7f04.7fb6`. Requires 3+ groups so a real
        // `first.last` or `a.b.c` name is never caught.
        let groups = localLower.split(separator: ".")
        if groups.count >= 3, groups.allSatisfy(isHexGroup) { return true }

        // A single long random token (no name separators) is a generated ID.
        if local.count >= 20, !local.contains("."), hasRandomTokenShape(local) { return true }

        return false
    }

    private static func isHexGroup(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit }
    }

    private static func isUUIDShaped(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 5 else { return false }
        let widths = [8, 4, 4, 4, 12]
        for (part, width) in zip(parts, widths) {
            guard part.count == width, part.allSatisfy(\.isHexDigit) else { return false }
        }
        return true
    }

    /// A local part a human would recognise as a name/role: mostly letters,
    /// with at most the usual name separators.
    private static func isHumanLooking(_ local: String) -> Bool {
        guard local.count <= 32 else { return false }
        let letters = local.filter(\.isLetter).count
        guard letters >= 3 else { return false }
        // Names are letter-dominant; generated tokens are not.
        return Double(letters) / Double(local.count) >= 0.7
    }

    /// Mixed-case + digits with no word structure — the signature of a
    /// base64-ish generated token. A long all-lowercase word (a real, if
    /// unusual, mailbox) is NOT flagged.
    private static func hasRandomTokenShape(_ local: String) -> Bool {
        let hasUpper = local.contains(where: \.isUppercase)
        let hasLower = local.contains(where: \.isLowercase)
        let hasDigit = local.contains(where: \.isNumber)
        return hasUpper && hasLower && hasDigit
    }

    // MARK: - 2. Truncated-variant collapse

    /// Drop addresses that are a strict SUFFIX of another address on the same
    /// domain — the signature of a wrapped/mis-decoded address. Order-stable:
    /// survivors keep their original relative order.
    public static func dropTruncatedVariants(_ addresses: [String]) -> [String] {
        guard addresses.count > 1 else { return addresses }
        // Group local parts by domain so `a@x.com` can never suppress `ba@y.com`.
        var localsByDomain: [String: [String]] = [:]
        for address in addresses {
            let lower = address.lowercased()
            guard let at = lower.lastIndex(of: "@") else { continue }
            let local = String(lower[lower.startIndex..<at])
            let domain = String(lower[lower.index(after: at)...])
            localsByDomain[domain, default: []].append(local)
        }
        return addresses.filter { address in
            let lower = address.lowercased()
            guard let at = lower.lastIndex(of: "@") else { return true }
            let local = String(lower[lower.startIndex..<at])
            let domain = String(lower[lower.index(after: at)...])
            guard let siblings = localsByDomain[domain] else { return true }
            // Suppressed only if some LONGER local part on this domain ends with it.
            return !siblings.contains { $0.count > local.count && $0.hasSuffix(local) }
        }
    }

    /// Both passes, in the order they must run: drop machine addresses first
    /// (so a machine ID can't anchor a suffix comparison), then collapse
    /// truncated variants of the survivors.
    public static func clean(_ addresses: [String]) -> [String] {
        dropTruncatedVariants(addresses.filter { !isMachineGenerated($0) })
    }
}
