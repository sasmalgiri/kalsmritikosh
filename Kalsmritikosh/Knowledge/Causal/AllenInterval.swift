//
//  AllenInterval.swift
//  Kalsmritikosh
//
//  HISTORY Phase G.6 — Allen's 13 base interval relations, pruned to
//  the 5 the research found most useful for a non-PhD investigation
//  audience. The other 8 are inverses or near-duplicates and can be
//  computed by reversing the link direction at query time.
//
//  Use cases:
//    1. The CausalDiscoverer stamps the Allen relation onto each new
//       link so downstream consumers don't recompute.
//    2. The composer renders prose using the relation: "X happened
//       DURING Y", "X met Y", "X overlapped Y", etc.
//
//  Inputs:
//    - A.start, optional A.end (Event has both)
//    - B.start, optional B.end
//  Outputs:
//    - One of {before, meets, overlaps, during, equals}, or nil
//      when the inputs are degenerate (e.g. identical instants).
//
//  Tolerance: 60 seconds. Two instants within 60s are treated as
//  equal — matches typical email-header clock skew. Below that
//  threshold "X happened before Y" is a brittle claim.
//

import Foundation

public nonisolated enum AllenInterval {
    /// Tolerance for equality of two instants, in seconds.
    public static let equalityToleranceSeconds: TimeInterval = 60

    /// Compute the Allen relation between intervals A and B.
    ///
    /// Returns nil when either interval is malformed (end < start)
    /// or when the relation falls outside the 5 base codes we ship.
    /// The composer treats nil as "no Allen claim" and just renders
    /// dates inline.
    public static func relation(
        aStart: Date, aEnd: Date? = nil,
        bStart: Date, bEnd: Date? = nil
    ) -> AllenRelation? {
        // Normalize: treat missing end as instant (end = start).
        let a1 = aStart
        let a2 = aEnd ?? aStart
        let b1 = bStart
        let b2 = bEnd ?? bStart
        guard a1 <= a2, b1 <= b2 else { return nil }

        let tol = equalityToleranceSeconds

        // EQUALS: same start AND same end (within tolerance).
        if abs(a1.timeIntervalSince(b1)) <= tol && abs(a2.timeIntervalSince(b2)) <= tol {
            return .equals
        }
        // BEFORE: A ends strictly before B starts (gap > tolerance).
        if a2.timeIntervalSince(b1) < -tol {
            return .before
        }
        // MEETS: A ends approximately when B starts (gap within tolerance).
        if abs(a2.timeIntervalSince(b1)) <= tol {
            return .meets
        }
        // DURING: A starts strictly after B starts AND A ends strictly
        // before B ends.
        if a1.timeIntervalSince(b1) > tol && a2.timeIntervalSince(b2) < -tol {
            return .during
        }
        // OVERLAPS: A starts before B starts AND A ends inside B
        // (between B.start and B.end).
        if a1.timeIntervalSince(b1) < -tol
            && a2.timeIntervalSince(b1) > tol
            && a2.timeIntervalSince(b2) < -tol {
            return .overlaps
        }
        // Otherwise — we don't ship the inverse (after / met-by /
        // overlapped-by / contains / starts / starts-by / finishes /
        // finishes-by). Caller reverses direction if useful.
        return nil
    }
}
