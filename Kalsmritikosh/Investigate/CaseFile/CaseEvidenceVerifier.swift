//
//  CaseEvidenceVerifier.swift
//  Kalsmritikosh
//
//  App Store completion instructions 2026-10-30 §2 — ONE meaning of "documentary evidence" for the
//  case file, ACH citations, report selections and job-result handoffs: a passage counts as
//  documentary support only when its exact source version is in the case and accessible under the
//  current policy, the block (or object) still exists in that version, and the quoted words are in
//  the pinned text — the same rules the studios already apply (`StudioEvidenceResolver`). A physical
//  exhibit must be live on the case's register. A typed note is the person's own entry. Anything that
//  fails is recorded as UNVERIFIED with the reason — never silently upgraded by a UUID.
//
//  Verification is re-run at every consequential write (an adverse finding, a reviewed report, an
//  export), so a source removed from the case, a withdrawn exhibit or a changed access label has an
//  explicit outcome at that moment. Quotation authenticity is separate from truth or legal merit.
//

import Foundation

/// What a case evidence reference is, once checked.
public nonisolated enum CaseEvidenceSupport: Equatable, Sendable {
    /// A verified passage: the exact source version, document and block the quoted words are in.
    case documentary(version: UUID, object: UUID?, block: UUID?)
    /// A physical exhibit live on this case's register.
    case exhibit(String)
    /// The investigator's own entry (a note); never documentary support.
    case note
    /// Not verified — the reason. Includes legacy links recorded before verification existed.
    case unverified(String)

    /// Counts as documentary support for an adverse finding or a reviewed report.
    public var isDocumentary: Bool {
        switch self {
        case .documentary, .exhibit: return true
        case .note, .unverified: return false
        }
    }
    /// The stored state ("verified", "exhibit", "note", "unverified").
    public var stored: String {
        switch self {
        case .documentary: return "verified"
        case .exhibit: return "exhibit"
        case .note: return "note"
        case .unverified: return "unverified"
        }
    }
    public var detail: String? {
        if case .unverified(let why) = self { return why }
        return nil
    }
    /// How a report or screen labels it.
    public var label: String {
        switch self {
        case .documentary: return "verified passage"
        case .exhibit(let n): return "exhibit \(n)"
        case .note: return "investigator's note"
        case .unverified(let why): return "unverified — \(why)"
        }
    }
    /// Rebuild from stored columns (a row with no stored state is a legacy, unverified link).
    public static func from(stored: String?, detail: String?, reference: String) -> CaseEvidenceSupport {
        switch stored {
        case "verified":
            if case .sourceVersion(let v) = CaseEvidenceReference.parse(reference) { return .documentary(version: v, object: nil, block: nil) }
            return .unverified("stored as verified but the reference is not a source version")
        case "exhibit":
            if case .exhibit(let n) = CaseEvidenceReference.parse(reference) { return .exhibit(n) }
            return .unverified("stored as an exhibit but the reference is not one")
        case "note": return .note
        case "unverified": return .unverified(detail ?? "not verified")
        default:
            if case .investigatorNote = CaseEvidenceReference.parse(reference) { return .note }
            return .unverified("recorded before passage verification existed — re-verify")
        }
    }
    public static let legacyReason = "recorded before passage verification existed — re-verify"
}

public nonisolated struct CaseEvidenceVerification: Equatable, Sendable {
    public let support: CaseEvidenceSupport
    /// The passage as resolved: a missing block locator is filled in when the quote is found in
    /// exactly one place in the version; the quote itself is never changed.
    public let passage: StudioEvidenceRef?
}

public nonisolated struct CaseEvidenceVerifier: Sendable {
    /// The case's evidence context under the export policy (eligible versions, case documents,
    /// block and document text) — nil when the case cannot be read.
    public typealias ContextLoader = @Sendable (_ caseID: UUID) async -> StudioEvidenceContext?
    public typealias ExhibitCheck = @Sendable (_ caseID: UUID, _ number: String) async -> Bool
    /// Every block of a source version with the document it belongs to, for resolving a missing locator.
    public typealias BlockLister = @Sendable (_ version: UUID) async -> [(id: UUID, object: UUID?, text: String)]

    let context: ContextLoader
    let exhibitLive: ExhibitCheck
    let blocksForVersion: BlockLister

    public init(context: @escaping ContextLoader, exhibitLive: @escaping ExhibitCheck, blocksForVersion: @escaping BlockLister) {
        self.context = context; self.exhibitLive = exhibitLive; self.blocksForVersion = blocksForVersion
    }

    /// Verify one reference (as the case file stores it) with its passage, in `caseID`.
    public func verify(reference raw: String, passage: StudioEvidenceRef?, caseID: UUID) async -> CaseEvidenceVerification {
        switch CaseEvidenceReference.parse(raw) {
        case .investigatorNote:
            return CaseEvidenceVerification(support: .note, passage: nil)
        case .unresolved:
            return CaseEvidenceVerification(support: .unverified("the reference names no source version, exhibit or investigator note"), passage: passage)
        case .exhibit(let number):
            let live = await exhibitLive(caseID, number)
            return CaseEvidenceVerification(support: live ? .exhibit(number) : .unverified("exhibit \(number) is not on this case's live register (withdrawn or never registered)"), passage: nil)
        case .sourceVersion(let version):
            guard let ctx = await context(caseID) else {
                return CaseEvidenceVerification(support: .unverified("the case's sources could not be read"), passage: passage)
            }
            guard ctx.eligibleSourceVersions.contains(version) else {
                return CaseEvidenceVerification(support: .unverified("the cited source is not in this case or is not accessible under the current policy"), passage: passage)
            }
            guard let quote = passage?.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else {
                return CaseEvidenceVerification(support: .unverified("the reference names a source but quotes no passage — a document alone does not state anything"), passage: passage)
            }
            var ref = passage ?? StudioEvidenceRef(sourceVersionID: version, quote: quote)
            if ref.sourceVersionID == nil { ref.sourceVersionID = version }
            if let pinned = ref.sourceVersionID, pinned != version {
                return CaseEvidenceVerification(support: .unverified("the passage is pinned to a different source version than the reference"), passage: passage)
            }
            // A pinned block or document: the studios' rules decide.
            if ref.blockID != nil || ref.objectID != nil {
                if let why = await StudioEvidenceResolver.check(ref, value: quote, kind: .text, ctx) {
                    return CaseEvidenceVerification(support: .unverified(why), passage: passage)
                }
                return CaseEvidenceVerification(support: .documentary(version: version, object: ref.objectID, block: ref.blockID), passage: ref)
            }
            // No locator: find the quoted words in the version's own blocks; pin the one place they are.
            let needle = StudioEvidenceResolver.norm(quote)
            let hits = await blocksForVersion(version).filter { StudioEvidenceResolver.norm($0.text).contains(needle) }
            guard let hit = hits.first else {
                return CaseEvidenceVerification(support: .unverified("the quoted words are not in the cited source"), passage: passage)
            }
            let resolved = StudioEvidenceRef(sourceVersionID: version, objectID: hit.object ?? ref.objectID, blockID: hit.id, quote: quote)
            return CaseEvidenceVerification(support: .documentary(version: version, object: resolved.objectID, block: hit.id), passage: resolved)
        }
    }
}
