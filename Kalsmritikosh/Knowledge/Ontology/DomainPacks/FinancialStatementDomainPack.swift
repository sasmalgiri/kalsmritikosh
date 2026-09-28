//
//  FinancialStatementDomainPack.swift
//  Kalsmritikosh
//
//  Starter pack — the FINANCIAL-STATEMENT domain (the finance / accountant
//  / compliance persona). Distinct from TransactionDomainPack, which reads
//  a single payment: this reads ACCOUNT-level records — bank statements,
//  credit-card statements, portfolio summaries — the account, the holder,
//  the statement period, and the balance. Optional, additive,
//  marker-gated. Deterministic, offline.
//

import Foundation

public enum FinancialStatementDomainPack {

    nonisolated static let markers: [String] = [
        "account statement", "statement of account", "account number",
        "opening balance", "closing balance", "available balance",
        "statement period", "account holder", "ifsc", "credit card statement",
        "portfolio", "a/c no",
    ]

    nonisolated static func isStatement(_ lower: String) -> Bool {
        markers.contains { lower.contains($0) }
    }

    /// accountNumber is an identifier (display constant "Account No.");
    /// balance is money; the rest text.
    public nonisolated static let emittedFields: [String] =
        ["accountNumber", "institution", "accountHolder", "statementPeriod", "balance"]

    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        let lower = text.lowercased()
        guard isStatement(lower) else { return [] }
        var facts: [GenericFact] = []

        if let v = DomainPackText.labeledIdentifier(after: ["account number", "account no", "a/c no", "a/c"], in: text) {
            facts.append(fact(subjectLabel, "accountNumber", v, blockID, 0.8, unit: nil))
        }
        if let v = DomainPackText.labeledValue(after: ["bank", "issued by", "institution", "branch"], in: text) {
            facts.append(fact(subjectLabel, "institution", v, blockID, 0.65, unit: nil))
        }
        if let v = DomainPackText.labeledValue(after: ["account holder", "name", "customer name"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "accountHolder", v, blockID, 0.7, unit: nil))
        }
        if let v = DomainPackText.labeledValue(after: ["statement period", "period", "for the period"], in: text) {
            facts.append(fact(subjectLabel, "statementPeriod", v, blockID, 0.6, unit: nil))
        }
        if lower.contains("balance"), let money = DomainPackText.firstMoney(in: text) {
            facts.append(fact(subjectLabel, "balance", money.replacingOccurrences(of: " ", with: ""),
                              blockID, 0.7, unit: DomainPackText.currencyUnit(money)))
        }
        return facts
    }

    nonisolated static func fact(_ subject: String, _ field: String, _ value: String,
                                 _ block: UUID, _ conf: Double, unit: String?) -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value, unit: unit,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }
}
