//
//  FactValuePlausibility.swift
//  Kalsmritikosh
//
//  Topic-Ledger Rebuild U4 (owner rule 1 hygiene, 2026-09-17) — a value gate that
//  keeps extraction noise out of the ledger. The live audit found `amount` full of
//  junk fragments ("rs,", "$0", "$1", "Rs9") — currency symbols with no real
//  magnitude. This rejects those deterministically at the write path, so a fact is
//  stored only when its value is substantive. Pure; conservative (it rejects only
//  clearly-empty/degenerate values, never a plausible one).
//

import Foundation

public enum FactValuePlausibility {

    /// Monetary field ids whose value must carry a real magnitude (≥ 2 digits) —
    /// so "$0" / "$1" / "rs," can't masquerade as an amount.
    static let monetaryFields: Set<String> = [
        "amount", "fee", "cost", "price", "salary", "consideration", "balance", "payment",
    ]

    // L2 (universal hygiene, 2026-09-26) — shapes that are never a FACT about
    // the world, whatever the domain. Found on the owner's real ledger:
    // "contenttype: multipart/mixed; boundary=…", "backgroundcolor: #ffffff;",
    // "arcseal: i=1; a=rsa-sha256". Transport plumbing and style sheets describe
    // the file, not its subject.
    static let transportFields: Set<String> = [
        "contenttype", "contenttransferencoding", "contentdisposition", "contentid", "cid",
        "mimeversion", "boundary", "charset", "xmailer", "xmimeole", "xoriginatingip",
        "returnpath", "received", "receivedspf", "dkimsignature", "xgoogledkimsignature",
        "arcseal", "arcmessagesignature", "arcauthenticationresults", "authenticationresults",
        "listunsubscribe", "messageid", "inreplyto", "references", "threadindex", "threadtopic",
        "precedence", "xpriority", "xmsmailpriority", "xgmthrid", "xgmmessagestate",
        "deliveredto", "envelopeto", "xreceived", "xsender", "xforwardedfor",
    ]
    static let styleFieldPrefixes: [String] = [
        "backgroundcolor", "background", "color", "font", "lineheight", "textalign",
        "textdecoration", "verticalalign", "whitespace", "margin", "padding", "border",
        "width", "height", "display", "mso", "letterspacing", "wordspacing", "overflow",
        "position", "zindex", "float", "clear", "opacity", "cursor", "listimage",
    ]

    /// A value that is markup, a style declaration or a MIME parameter list.
    nonisolated static func isMarkupOrStyle(_ v: String) -> Bool {
        let lower = v.lowercased()
        if lower.hasPrefix("multipart/") || lower.hasPrefix("text/html") || lower.hasPrefix("text/plain")
            || lower.hasPrefix("application/") || lower.hasPrefix("image/") { return true }
        if lower.contains("</") || lower.contains("&#") || lower.contains("&nbsp") { return true }
        if lower.range(of: #"^#[0-9a-f]{3,8}\b"#, options: .regularExpression) != nil { return true }
        if lower.contains("{") || lower.contains("}") { return true }
        if lower.hasSuffix(";") && lower.contains(":") { return true }          // "a: b; c: d;"
        if lower.range(of: #"\b(boundary|charset|filename)="#, options: .regularExpression) != nil { return true }
        return false
    }

    /// A form's empty slot: underscores, dot leaders, or dash rules.
    nonisolated static func isPlaceholder(_ v: String) -> Bool {
        v.range(of: #"_{3,}|\.{4,}|-{4,}"#, options: .regularExpression) != nil
    }

    /// Whether a (field, value) is substantive enough to store.
    public nonisolated static func isAcceptable(field: String, value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count >= 2 else { return false }                 // "", "a", "$" — not a fact
        // Must carry at least one letter or digit (not pure punctuation like "-" or "=").
        guard v.contains(where: { $0.isLetter || $0.isNumber }) else { return false }

        let f = field.lowercased()
        if transportFields.contains(f) { return false }
        if styleFieldPrefixes.contains(where: { f.hasPrefix($0) }) && !f.hasPrefix("colour") { return false }
        if isMarkupOrStyle(v) || isPlaceholder(v) { return false }
        if monetaryFields.contains(where: { f.contains($0) }) {
            // A real amount needs a magnitude: at least two digits somewhere
            // ("$27", "5,00,000") — this drops "rs,", "$0", "$1", "Rs9".
            let digitCount = v.filter(\.isNumber).count
            return digitCount >= 2
        }
        return true
    }
}
