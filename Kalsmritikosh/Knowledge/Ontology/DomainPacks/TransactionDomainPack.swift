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
        } else if isPaymentConfirmation(text),
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

    nonisolated static func normalize(_ amount: String) -> String {
        amount.replacingOccurrences(of: " ", with: "")
    }

    nonisolated static func currencyUnit(_ amount: String) -> String? {
        let a = amount.lowercased()
        if a.contains("₹") || a.contains("rs") || a.contains("inr") { return "INR" }
        if a.contains("$") { return "USD" }
        return nil
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
