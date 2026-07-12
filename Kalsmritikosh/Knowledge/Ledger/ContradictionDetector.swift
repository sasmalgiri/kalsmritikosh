//
//  ContradictionDetector.swift
//  Kalsmritikosh
//
//  System 3 — rule-based conflict detection. Pure, stateless, NO LLM and
//  NO database access: a function over already-extracted Events that
//  returns Contradictions for a repository to persist.
//
//  Current rule — SAME-EVENT TEMPORAL CONFLICT:
//    When two INDEPENDENT sources describe what looks like the same event
//    (same kind + same normalized title) but assign materially different
//    dates, that's a contradiction in the archive. We only compare dates
//    that are day-precision or finer (a month-precision "in March" can't
//    contradict "March 14"), and only across different source documents
//    (one document isn't in conflict with itself).
//
//  Design guards:
//    * Coarse-precision events (month / quarter / year / unknown) are
//      excluded — comparing them by day would manufacture false conflicts.
//    * A conflict needs TWO distinct source objects.
//    * Output is capped so one pathological title can't flood the ledger.
//

import Foundation

public nonisolated struct ContradictionDetector: Sendable {

    public nonisolated init() {}

    /// Flag events that appear to be the same occurrence but are dated
    /// differently by different sources.
    ///
    /// - Parameters:
    ///   - events: candidate events (already fetched from the ledger).
    ///   - toleranceDays: how far two dates may differ before it counts
    ///     as a conflict. Default 2 days absorbs timezone / rounding noise.
    ///   - limit: max contradictions returned.
    public func detectEventDateConflicts(
        _ events: [Event],
        toleranceDays: Double = 2,
        limit: Int = 50
    ) -> [Contradiction] {
        // Only day-precision-or-finer events can meaningfully conflict on date.
        let dated = events.filter { $0.datePrecision.rawValue >= DatePrecision.day.rawValue }

        // Group by (kind + normalized title) — our proxy for "same event".
        var groups: [String: [Event]] = [:]
        for e in dated {
            let key = Self.normalizedTitle(e.title)
            guard key.count >= 4 else { continue }   // skip junk / too-generic titles
            groups["\(e.kind.rawValue)|\(key)", default: []].append(e)
        }

        let tolerance = toleranceDays * 86_400
        var out: [Contradiction] = []

        for (_, group) in groups {
            guard group.count >= 2 else { continue }
            let sorted = group.sorted { $0.date < $1.date }
            guard let earliest = sorted.first, let latest = sorted.last else { continue }

            // Two distinct sources, dates far enough apart.
            guard earliest.sourceObjectID != latest.sourceObjectID else { continue }
            let gap = latest.date.timeIntervalSince(earliest.date)
            guard gap > tolerance else { continue }

            let gapDays = gap / 86_400
            out.append(Contradiction(
                kind: .date,
                description: "Conflicting dates for \"\(latest.title)\"",
                claimA: "\(earliest.title) \(earliest.datePrecision.renderPhrase(date: earliest.date))",
                claimB: "\(latest.title) \(latest.datePrecision.renderPhrase(date: latest.date))",
                evidenceA: earliest.sourceObjectID,
                evidenceB: latest.sourceObjectID,
                severity: Self.severity(
                    gapDays: gapDays,
                    confidenceA: earliest.dateConfidence,
                    confidenceB: latest.dateConfidence
                )
            ))
            if out.count >= limit { break }
        }
        return out
    }

    /// A5.6 — SAME-EVENT AMOUNT CONFLICT. When two independent sources describe
    /// what looks like the same financial event (same kind + normalized title)
    /// but state materially different monetary amounts in the SAME currency,
    /// that's an amount contradiction. Amounts live in `event.attributes`
    /// (A5.3): `amount` (Double) + `currency` (ISO code). Cross-currency pairs
    /// are NOT flagged — differing units aren't a disagreement. Two distinct
    /// sources required; output capped.
    ///
    /// - Parameters:
    ///   - events: candidate events (already fetched from the ledger).
    ///   - relativeTolerance: fraction of the larger amount two values may
    ///     differ by before it counts as a conflict (absorbs rounding). Default
    ///     0.005 (0.5%).
    ///   - limit: max contradictions returned.
    public func detectEventAmountConflicts(
        _ events: [Event],
        relativeTolerance: Double = 0.005,
        limit: Int = 50
    ) -> [Contradiction] {
        // Only events that actually carry a parsed amount can conflict.
        let withAmount = events.compactMap { e -> (Event, Double, String)? in
            guard let money = Self.amount(of: e) else { return nil }
            return (e, money.value, money.currency)
        }

        // Group by (kind + normalized title) — proxy for "same financial event".
        var groups: [String: [(Event, Double, String)]] = [:]
        for item in withAmount {
            let key = Self.normalizedTitle(item.0.title)
            guard key.count >= 4 else { continue }
            groups["\(item.0.kind.rawValue)|\(key)", default: []].append(item)
        }

        var out: [Contradiction] = []
        for (_, group) in groups {
            guard group.count >= 2 else { continue }
            // Compare the smallest vs largest amount within the SAME currency.
            let byCurrency = Dictionary(grouping: group, by: { $0.2 })
            for (currency, sameCurrency) in byCurrency {
                guard sameCurrency.count >= 2 else { continue }
                let sorted = sameCurrency.sorted { $0.1 < $1.1 }
                guard let low = sorted.first, let high = sorted.last else { continue }
                guard low.0.sourceObjectID != high.0.sourceObjectID else { continue }
                let diff = high.1 - low.1
                let tolerance = max(high.1, low.1) * relativeTolerance
                guard diff > tolerance else { continue }

                out.append(Contradiction(
                    kind: .amount,
                    description: "Conflicting amounts for \"\(high.0.title)\"",
                    claimA: "\(low.0.title): \(Self.renderAmount(low.1, currency))",
                    claimB: "\(high.0.title): \(Self.renderAmount(high.1, currency))",
                    evidenceA: low.0.sourceObjectID,
                    evidenceB: high.0.sourceObjectID,
                    severity: Self.amountSeverity(
                        low: low.1, high: high.1,
                        confidenceA: low.0.confidence, confidenceB: high.0.confidence
                    )
                ))
                if out.count >= limit { break }
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// A5.6 — CAUSAL CONFLICT. Two independent sources assert incompatible
    /// cause-and-effect between the same pair of events: opposite directions
    /// (A caused B vs B caused A) or the same direction with contradictory
    /// relations (A caused B vs A prevented B). Cross-source only — one source
    /// isn't in conflict with itself. Output capped.
    ///
    /// - Parameters:
    ///   - links: causal links from the ledger.
    ///   - title: event title lookup for readable claims.
    public func detectCausalConflicts(
        _ links: [CausalLink],
        title: [Event.ID: String],
        limit: Int = 50
    ) -> [Contradiction] {
        // Group by the unordered event pair.
        func pairKey(_ a: UUID, _ b: UUID) -> String {
            let s = [a.uuidString, b.uuidString].sorted()
            return "\(s[0])|\(s[1])"
        }
        let positive: Set<CausalRelation> = [.caused, .contributedTo, .enabled]
        var groups: [String: [CausalLink]] = [:]
        for l in links where l.supersededBy == nil {
            groups[pairKey(l.sourceEventID, l.targetEventID), default: []].append(l)
        }

        var out: [Contradiction] = []
        for (_, group) in groups where group.count >= 2 {
            outer: for i in group.indices {
                for j in (i + 1)..<group.count {
                    let a = group[i], b = group[j]
                    // Different sources only.
                    let evA = Set(a.evidenceObjectIDs), evB = Set(b.evidenceObjectIDs)
                    guard evA.isDisjoint(with: evB) else { continue }

                    let reversed = a.sourceEventID == b.targetEventID
                        && a.targetEventID == b.sourceEventID
                    let oppositeCausation = reversed
                        && positive.contains(a.relation) && positive.contains(b.relation)
                    // A5.6 sequence — opposite temporal ordering (A followed B
                    // vs B followed A) is a sequence conflict, not causal.
                    let oppositeSequence = reversed
                        && a.relation == .followed && b.relation == .followed
                    let sameDirContradictoryRelation = a.sourceEventID == b.sourceEventID
                        && a.targetEventID == b.targetEventID
                        && ((a.relation == .prevented) != (b.relation == .prevented))
                    guard oppositeCausation || oppositeSequence || sameDirContradictoryRelation else { continue }

                    func name(_ id: Event.ID) -> String { title[id] ?? "an event" }
                    let kind: Contradiction.Kind = oppositeSequence ? .sequence : .causation
                    out.append(Contradiction(
                        kind: kind,
                        description: (oppositeSequence ? "Conflicting order between " : "Conflicting cause-and-effect between ") + "\"\(name(a.sourceEventID))\" and \"\(name(a.targetEventID))\"",
                        claimA: "\(name(a.sourceEventID)) \(a.relation.renderVerb) \(name(a.targetEventID))",
                        claimB: "\(name(b.sourceEventID)) \(b.relation.renderVerb) \(name(b.targetEventID))",
                        evidenceA: a.evidenceObjectIDs.first,
                        evidenceB: b.evidenceObjectIDs.first,
                        severity: min(a.confidence, b.confidence) >= 0.7 ? .high : .medium
                    ))
                    if out.count >= limit { return out }
                    break outer
                }
            }
        }
        return out
    }

    // MARK: Helpers

    /// Pull the parsed amount + currency an event carries (A5.3), if any.
    static func amount(of event: Event) -> (value: Double, currency: String)? {
        guard case .double(let value)? = event.attributes["amount"]?.value else { return nil }
        let currency: String
        if case .string(let c)? = event.attributes["currency"]?.value { currency = c } else { currency = "" }
        return (value, currency)
    }

    private static func renderAmount(_ value: Double, _ currency: String) -> String {
        let n = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
        return currency.isEmpty ? n : "\(currency) \(n)"
    }

    /// A larger relative gap between two confidently-stated amounts is more
    /// severe than a tiny gap between shaky ones.
    private static func amountSeverity(
        low: Double, high: Double,
        confidenceA: Confidence, confidenceB: Confidence
    ) -> Contradiction.Severity {
        let ratio = high > 0 ? (high - low) / high : 0
        let bothConfident = confidenceA == .high && confidenceB == .high
        if ratio > 0.25 && bothConfident { return .high }
        if ratio > 0.05 { return .medium }
        return .low
    }

    /// A bigger disagreement between two confidently-dated sources is more
    /// severe than a few days' slip between shaky ones.
    private static func severity(gapDays: Double, confidenceA: Double, confidenceB: Double) -> Contradiction.Severity {
        let bothConfident = min(confidenceA, confidenceB) >= 0.7
        if gapDays > 30 && bothConfident { return .high }
        if gapDays > 7 { return .medium }
        return .low
    }

    /// Lowercase, trim, collapse internal whitespace — so "Kickoff  Call"
    /// and "kickoff call" group together.
    static func normalizedTitle(_ title: String) -> String {
        let lowered = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = lowered.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }
}
