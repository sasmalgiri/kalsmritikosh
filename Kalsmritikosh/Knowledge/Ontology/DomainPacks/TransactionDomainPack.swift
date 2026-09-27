//
//  TransactionDomainPack.swift
//  Kalsmritikosh
//
//  SEM-005 — the transaction/payment domain pack. A domain pack is OPTIONAL: it improves
//  extraction for a known domain (here: receipts, invoices, bank statements) by registering
//  block recognizers and a deterministic fact extractor. Its ABSENCE must never block
//  structural search or cited answers — the generic layer still works.
//
//  Distinguishes receipt / bank / invoice by signal, and extracts amount + counterparty +
//  date as evidence-linked GenericFacts with SOURCE_ASSERTED status (a receipt records what
//  it claims; it does not by itself establish truth). Deterministic, offline.
//

import Foundation

public enum TransactionDomainPack {

    /// Block recognizers this pack contributes to the semantics registry (SEM-002).
    public nonisolated static var recognizers: [BlockRecognizer] {
        [
            BlockRecognizer(name: "txnReference") { text, _ in
                let t = text.lowercased()
                let hit = t.contains("transaction id") || t.contains("txn id") || t.contains("utr")
                    || t.contains("reference no") || t.contains("upi ref")
                return hit ? BlockSemanticTag(role: "transactionReference", confidence: 0.75, recognizedBy: "txnReference") : nil
            },
            BlockRecognizer(name: "payeeLine") { text, _ in
                let t = text.lowercased()
                let hit = t.contains("paid to") || t.contains("payee") || t.contains("beneficiary")
                    || t.contains("transferred to") || t.contains("to:")
                return hit ? BlockSemanticTag(role: "payeeLine", confidence: 0.7, recognizedBy: "payeeLine") : nil
            }
        ]
    }

    /// A registry extended with this pack (domain packs compose additively).
    public nonisolated static func registry(base: BlockSemanticsRegistry = .generic) -> BlockSemanticsRegistry {
        recognizers.reduce(base) { $0.registering($1) }
    }

    /// The fields this pack emits under producer_version=1 — the display-contract
    /// completeness authority. amount = money (renderMoney canon); counterparty =
    /// org/name (org normalizer at comparison); date = precision-canon (inherited).
    public nonisolated static let emittedFields: [String] = ["amount", "counterparty", "date"]

    /// Extract transaction facts (amount, counterparty, date) from receipt-like text.
    /// Returns evidence-linked GenericFacts; empty when the text isn't transactional.
    /// V2 (A3): amount keeps its EXISTING normalizer (the reference pattern — never
    /// a parallel one); the date stores the precision-aware ISO ATOM via the
    /// inherited C-7 normalizer; counterparty stores the source name faithfully,
    /// its legal-suffix variance trimmed by the comparator's org normalizer AT
    /// COMPARISON (dedup) without collapsing distinct stems. All stamped v1.
    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        var facts: [GenericFact] = []

        if let amount = firstMatch(#"(?:₹|rs\.?|inr|\$)\s?[\d,]+(?:\.\d{1,2})?"#, in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "amount", value: normalize(amount),
                                     unit: currencyUnit(amount), status: .sourceAsserted,
                                     confidence: 0.8, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: amount, sourceCount: 1))
        } else if isPaymentConfirmation(text) || hasReceiptFurniture(text),
                  let ocr = firstMatch(#"[·•]\s?\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?"#, in: text) {
            // P2 (payments) — OCR routinely reads a rupee sign as "·" on payment
            // screenshots ("YES BANK ·10,000"). Only in a payment confirmation,
            // only a thousands-grouped figure: the sign is the one OCR lost.
            let digits = ocr.drop { !$0.isNumber }
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "amount", value: "₹" + digits,
                                     unit: "INR", status: .sourceAsserted,
                                     confidence: 0.65, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: ocr, sourceCount: 1))
        }
        if let payee = counterparty(in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "counterparty", value: payee,
                                     status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: payee, sourceCount: 1))
        }
        if let raw = firstMatch(#"\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b"#, in: text),
           let iso = PatentDomainPack.normalizeDate(raw) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "date", value: iso,
                                     status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        } else if let raw = firstMatch(#"\b\d{1,2}\s(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?,?\s\d{4}\b"#, in: text),
                  let iso = writtenDate(raw) {
            // Receipts write "05 Dec 2024" — the numeric pattern never saw it.
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "date", value: iso,
                                     status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        }
        return facts
    }

    // MARK: - Helpers

    nonisolated static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func writtenDate(_ raw: String) -> String? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "Sept", with: "Sep").replacingOccurrences(of: "sept", with: "sep")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["d MMM yyyy", "d MMMM yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: cleaned) {
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: d)
            }
        }
        return nil
    }

    nonisolated static func normalize(_ amount: String) -> String {
        amount.replacingOccurrences(of: " ", with: "")
    }

    nonisolated static func currencyUnit(_ amount: String) -> String? {
        let a = amount.lowercased()
        if a.contains("₹") || a.contains("rs") || a.contains("inr") { return "INR" }
        if a.contains("$") { return "USD" }
        return nil
    }

    /// A payment document's amount when OCR lost the currency sign: every
    /// thousands-grouped figure prefixed by a currency-like glyph (·, •, R, ₺,
    /// ₹) anywhere in the document, the value the most variants agree on (a
    /// "₹" misread as a leading "2" loses the vote). Only for a document with
    /// a payment-confirmation block. nil when no figure qualifies.
    public nonisolated static func documentLevelAmount(
        blocks: [(id: UUID, text: String)], subjectLabel: String
    ) -> GenericFact? {
        guard blocks.contains(where: { isPaymentConfirmation($0.text) }),
              let re = try? NSRegularExpression(pattern: #"(?:^|[\s\t<>])[·•R₺₹]\s?(\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?)(?![\d,])"#)
        else { return nil }
        var votes: [String: (count: Int, block: UUID, raw: String)] = [:]
        for b in blocks {
            let ns = b.text as NSString
            for m in re.matches(in: b.text, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: m.range(at: 1))
                let raw = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                let prior = votes[value]
                votes[value] = ((prior?.count ?? 0) + 1, prior?.block ?? b.id, prior?.raw ?? raw)
            }
        }
        guard let (value, win) = votes.max(by: { a, b in
            a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key
        }) else { return nil }
        return GenericFact(subjectLabel: subjectLabel, field: "amount", value: "₹" + value, unit: "INR",
                           status: .sourceAsserted, confidence: win.count >= 2 ? 0.7 : 0.55,
                           sourceBlockIDs: [win.block], producerVersion: DerivedProducerVersions.facts,
                           rawMatch: win.raw, sourceCount: 1)
    }

    /// The furniture of a bank/UPI receipt — OCR splits a screenshot into
    /// blocks, so the amount's own block ("Powered by YES BANK ·10,000") may not
    /// carry "paid to". Only ever used for the OCR-lost-sign amount.
    nonisolated static func hasReceiptFurniture(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["utr", "upi", "powered by", "debited", "bank transfer", "transaction id", " bank "].contains { t.contains($0) }
    }

    /// A payment CONFIRMATION (not merely a mention of money).
    nonisolated static func isPaymentConfirmation(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["paid to", "transaction successful", "payment successful", "transferred to",
                "debited from", "amount paid", "payment of"].contains { t.contains($0) }
    }

    /// Words that END a payee name on a one-line OCR receipt ("Paid to X
    /// XXXX1671 Axis Bank Transfer Details Transaction ID …").
    nonisolated static let payeeStops: Set<String> = [
        "transfer", "details", "transaction", "txn", "upi", "utr", "ref", "reference", "a/c", "ac",
        "account", "debited", "credited", "on", "via", "using", "from", "amount", "rs", "inr", "id",
    ]

    /// Extract the counterparty after a payee marker: up to punctuation, a
    /// masked or numeric run, a payment-furniture word, or eight words.
    nonisolated static func counterparty(in text: String) -> String? {
        let markers = ["paid to", "payee", "beneficiary", "transferred to", "to:"]
        let lower = text.lowercased()
        for m in markers {
            guard let r = lower.range(of: m) else { continue }
            let after = text[r.upperBound...]
            let trimmed = after.drop { $0 == ":" || $0 == " " }
            let clause = trimmed.prefix { !"\n.,;|".contains($0) }
            var words: [String] = []
            for raw in clause.split(whereSeparator: { $0.isWhitespace }) {
                let w = String(raw)
                let lw = w.lowercased()
                if payeeStops.contains(lw) { break }
                if w.contains(where: \.isNumber) || (w.count >= 4 && w.uppercased().allSatisfy({ $0 == "X" })) { break }
                words.append(w)
                if words.count == 8 { break }
            }
            let name = words.joined(separator: " ")
            if name.count >= 2 && name.count <= 60 { return name }
        }
        return nil
    }
}
