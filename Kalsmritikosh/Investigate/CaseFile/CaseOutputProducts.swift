//
//  CaseOutputProducts.swift
//  Kalsmritikosh
//
//  Smart-map S11 (milestone M5, docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §OUTPUT) — reviewed case
//  products, all through the ONE output door (CaseOutputService: freeze, revalidate, protect, release, read back, record):
//
//  • OUTPUT-02 — every product is frozen under the case's revision fence: the fence is read before and after the case is
//    read, a change in between reads again and finally refuses (`keptChanging`), so a concurrent edit can never produce a
//    mixed-state output. The fence, the selection, the counts and the pinned record revisions travel as the output's
//    manifest and are stored with its record (case_document_outputs.manifest_json, schema v187).
//  • OUTPUT-03 / OUTPUT-04 / OUTPUT-05 — the portable case package: one static HTML file (no script, no external fetch,
//    a Content-Security-Policy that forbids both) for the whole permitted case, a branch, a briefing or chosen records with
//    the records they rest on; every item and link marked supplied / inferred / reviewed / unresolved; source locators and
//    quotes, findings and decisions, open work and action outcomes, the money report; what was left out disclosed by count
//    (restricted content by count only, never by title).
//  • OUTPUT-07 — the written file is parsed back and reconciled with its manifest (row counts per section, active-content
//    check, PDF pages, PNG image, CSV rows) before it is recorded as an export.
//  • OUTPUT-08 — approval of one kind of output at one revision fence. An output that presents conclusions states its
//    revision and either that exact approval or DRAFT; a change to the case or a withdrawn approval refuses the release.
//  • OUTPUT-01 — the review case's own record, the money report and a briefing leave through the same door.
//
//  No AI, no network. Pure rendering + the ledger reads the case services already expose.
//

import CoreGraphics
import Foundation
import ImageIO
import os

// MARK: - Manifest (OUTPUT-02 / OUTPUT-07)

/// What an output froze: the revision of the case it was read at, what was selected, how many of each thing it holds,
/// the revisions of the records in it, the source versions it cites and what was left out.
public nonisolated struct CaseOutputManifest: Codable, Sendable, Equatable {
    public var formatVersion = 1
    public var caseID: UUID
    public var kind: String
    /// The case's output revision fence (CaseOutputService.outputFence) at the freeze.
    public var revisionFence: String
    public var scopeFingerprint: String?
    public var readAt: Date
    public var selection: String
    /// "text", "html", "csv", "pdf" or "png" — how the written bytes are parsed back.
    public var format: String
    public var counts: [String: Int]
    /// Record key → its revision when frozen.
    public var pinned: [String: String]
    public var sourceVersions: [String]
    /// What was left out, by category (counts only).
    public var omitted: [String: Int]
    public var approval: String?
    /// "approved" or "draft".
    public var state: String

    public init(caseID: UUID, kind: CaseOutputKind, revisionFence: String, scopeFingerprint: String?, readAt: Date, selection: String, format: String,
                counts: [String: Int], pinned: [String: String], sourceVersions: [String], omitted: [String: Int], approval: String?, state: String) {
        self.caseID = caseID; self.kind = kind.rawValue; self.revisionFence = revisionFence; self.scopeFingerprint = scopeFingerprint
        self.readAt = readAt; self.selection = selection; self.format = format; self.counts = counts; self.pinned = pinned
        self.sourceVersions = sourceVersions; self.omitted = omitted; self.approval = approval; self.state = state
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Deterministic JSON (sorted keys).
    public var json: String? {
        do { return String(decoding: try Self.encoder.encode(self), as: UTF8.self) } catch {
            KalsmritikoshLog.app.error("Output manifest not encoded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    public static func decode(_ json: String) -> CaseOutputManifest? {
        do { return try decoder.decode(CaseOutputManifest.self, from: Data(json.utf8)) } catch {
            KalsmritikoshLog.app.error("Output manifest not decoded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Read-back reconciliation (OUTPUT-07)

public nonisolated enum CaseOutputArtifactCheck {
    /// Why the written bytes do not reconcile with the manifest, or nil when they do.
    public static func problem(_ data: Data, manifest m: CaseOutputManifest) -> String? {
        switch m.format {
        case "html":
            guard let text = String(data: data, encoding: .utf8) else { return "the package is not UTF-8 text" }
            let read = CasePortablePackageReader.read(text, sectionText: false)
            if let v = read.violations.first { return "active content: \(v)" }
            if !read.brokenAnchors.isEmpty { return "\(read.brokenAnchors.count) link(s) inside the package lead nowhere" }
            guard let embedded = read.manifest else { return "the package's manifest could not be read back" }
            if embedded.revisionFence != m.revisionFence { return "the package names another case revision" }
            for (key, n) in m.counts where CasePortablePackageReader.rowKinds[key] != nil {
                let found = read.rows[CasePortablePackageReader.rowKinds[key] ?? ""] ?? 0
                if found != n { return "\(key): \(found) row(s) written, \(n) frozen" }
            }
            return nil
        case "csv":
            guard let text = String(data: data, encoding: .utf8) else { return "the table is not UTF-8 text" }
            let lines = text.components(separatedBy: "\n")
            let links = lines.filter { $0.hasPrefix("link,") }.count, items = lines.filter { $0.hasPrefix("item,") }.count
            if let n = m.counts["links"], n != links { return "links: \(links) row(s) written, \(n) frozen" }
            if let n = m.counts["items"], n != items { return "items: \(items) row(s) written, \(n) frozen" }
            return nil
        case "pdf":
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else { return "the PDF does not open" }
            return pdf.numberOfPages >= 1 ? nil : "the PDF has no pages"
        case "png":
            guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) == 1,
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil), image.width > 0 else { return "the image does not decode" }
            return nil
        default:
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return "the text does not read back" }
            if CaseOutputKind(rawValue: m.kind)?.presentsConclusions == true, !text.contains(String(m.revisionFence.prefix(12))) {
                return "the written text does not state the case revision it was frozen at"
            }
            return nil
        }
    }
}

// MARK: - Approvals (OUTPUT-08)

public nonisolated struct CaseOutputApproval: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let kind: CaseOutputKind
    public let revisionFence: String
    public let approvedBy: String
    public let approvedAt: Date
    public let note: String?
    /// The case is worked alone: the approver is also its investigator (labelled, never hidden).
    public let selfReview: Bool
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public var isActive: Bool { withdrawnAt == nil }
}

// MARK: - Selection (OUTPUT-03)

public nonisolated enum CasePackageSelection: Sendable, Equatable {
    /// Every item of the case the person may export.
    case wholeCase
    /// A frame and everything placed in it (recursively), or an item and its direct neighbours.
    case branch(CaseMapNodeID)
    /// A briefing's steps (frames expanded as branches).
    case briefing(UUID)
    /// Chosen records.
    case records([CaseMapNodeID])

    public var label: String {
        switch self {
        case .wholeCase: return "The whole case (every item you may export)"
        case .branch: return "One branch of the case"
        case .briefing: return "One briefing"
        case .records(let r): return "\(r.count) chosen record(s)"
        }
    }
}

/// How a recipient can tell what each row is (OUTPUT-04).
public nonisolated enum CasePackageProvenance: String, Sendable, CaseIterable {
    /// From the material supplied to the case (documents, statements, verified passages).
    case supplied
    /// Drawn by a person, a rule or the AI from that material — not yet a reviewed decision.
    case inferred
    /// Decided on review (accepted, confirmed, dismissed, explained, completed).
    case reviewed
    /// Open: waiting for review, changed since, not assessed, or examined and left unresolved.
    case unresolved

    public var label: String {
        switch self {
        case .supplied: return "Supplied"
        case .inferred: return "Inferred"
        case .reviewed: return "Reviewed"
        case .unresolved: return "Unresolved"
        }
    }
    public var meaning: String {
        switch self {
        case .supplied: return "From the material supplied to the case (documents, statements, verified passages)."
        case .inferred: return "Drawn from that material by a person, a rule or the AI — not a reviewed decision."
        case .reviewed: return "Decided on review (accepted, confirmed, dismissed, explained or completed)."
        case .unresolved: return "Open: waiting for review, changed since it was decided, not yet assessed, or left unresolved."
        }
    }

    static let reviewedStates: Set<CaseMapReviewState> = [.accepted, .completed, .confirmed, .dismissed, .rejected, .explained]

    public static func of(_ n: CaseMapNode) -> CasePackageProvenance {
        if n.review.awaitingReview || n.review == .unresolved || [.stale, .unassessed, .failed].contains(n.status.kind) || n.kind == .question { return .unresolved }
        if reviewedStates.contains(n.review) { return .reviewed }
        switch n.author {
        case .rule?, .model?: return .inferred
        default: break
        }
        if n.isDocumentary || n.kind == .evidence || n.kind == .statement { return .supplied }
        if [.hypothesis, .finding, .note, .contradiction].contains(n.kind) { return .inferred }
        return n.sources.isEmpty ? .inferred : .supplied
    }

    public static func of(_ l: CaseMapLink) -> CasePackageProvenance {
        if l.review.awaitingReview || l.review == .unresolved || [.stale, .unassessed, .failed].contains(l.status.kind) { return .unresolved }
        if reviewedStates.contains(l.review) { return .reviewed }
        return .inferred
    }
}

// MARK: - The package content (OUTPUT-03..05)

public nonisolated struct CasePackageContent: Sendable, Equatable {
    public struct Item: Sendable, Equatable { public var anchor, key, kind, title, wording, provenance, state, review, dates, sources, addedBecause, revision: String }
    public struct Relation: Sendable, Equatable { public var fromAnchor, from, type, toAnchor, to, why, assertedBy, provenance, state, sources: String }
    public struct Evidence: Sendable, Equatable {
        public var anchor, document, locator, quote, version: String
        /// S16 (ARCH-05) — whether the cited place is available now, read from the ledger at preparation (filled by the service).
        public var availableNow: String = "not checked"
    }
    /// S16 (ARCH-05) — what a typed reference is built from: the holder, the evidence row it is shown as, and who asserted it.
    public struct ReferenceInput: Sendable, Equatable { public var holder, anchor, provenance: String; public var source: CaseMapSourceRef }
    public struct Finding: Sendable, Equatable { public var itemAnchor, title, kind, provenance, decision, history: String }
    public struct OpenWork: Sendable, Equatable { public var itemAnchor, title, reason: String }
    public struct Step: Sendable, Equatable { public var title, state, change: String }

    public var title: String
    public var header: [String]
    public var items: [Item]
    public var relations: [Relation]
    public var evidence: [Evidence]
    public var findings: [Finding]
    public var openWork: [OpenWork]
    public var steps: [Step]
    public var money: String
    public var disclosures: [String]
    public var citations: [StudioEvidenceRef]
    public var pinned: [String: String]
    public var omitted: [String: Int]
    /// S16 (ARCH-05) — one typed reference per shown source of an included item or link (object, exact version, locator,
    /// availability now, scope, who asserted it). Built by the service from `referenceInputs`; a missing original or an
    /// out-of-scope version is written as such.
    public var referenceInputs: [ReferenceInput] = []
    public var references: [CaseTypedReference] = []

    public var counts: [String: Int] {
        ["items": items.count, "links": relations.count, "evidence": evidence.count, "findings": findings.count, "openWork": openWork.count,
         "steps": steps.count, "disclosures": disclosures.count, "references": references.count]
    }

    /// Every text a recipient reads, passed through `f` (protection).
    func mapped(_ f: (String) throws -> String) rethrows -> CasePackageContent {
        var c = self
        c.title = try f(title); c.header = try header.map(f)
        c.items = try items.map { Item(anchor: $0.anchor, key: $0.key, kind: $0.kind, title: try f($0.title), wording: try f($0.wording), provenance: $0.provenance,
                                       state: try f($0.state), review: $0.review, dates: $0.dates, sources: try f($0.sources), addedBecause: try f($0.addedBecause),
                                       revision: $0.revision) }
        c.relations = try relations.map { Relation(fromAnchor: $0.fromAnchor, from: try f($0.from), type: $0.type, toAnchor: $0.toAnchor, to: try f($0.to),
                                                   why: try f($0.why), assertedBy: try f($0.assertedBy), provenance: $0.provenance, state: try f($0.state),
                                                   sources: try f($0.sources)) }
        c.evidence = try evidence.map { Evidence(anchor: $0.anchor, document: try f($0.document), locator: try f($0.locator), quote: try f($0.quote), version: $0.version,
                                                 availableNow: $0.availableNow) }
        c.references = try references.map { var r = $0; r.provenance = try f(r.provenance); return r }
        c.findings = try findings.map { Finding(itemAnchor: $0.itemAnchor, title: try f($0.title), kind: $0.kind, provenance: $0.provenance, decision: try f($0.decision),
                                                history: try f($0.history)) }
        c.openWork = try openWork.map { OpenWork(itemAnchor: $0.itemAnchor, title: try f($0.title), reason: try f($0.reason)) }
        c.steps = try steps.map { Step(title: try f($0.title), state: try f($0.state), change: try f($0.change)) }
        c.money = try f(money)
        c.disclosures = try disclosures.map(f)
        return c
    }

    /// Every text in the package (for the protected-identity check of the bytes).
    var texts: [String] {
        [title] + header + items.flatMap { [$0.title, $0.wording, $0.state, $0.sources, $0.addedBecause] }
            + relations.flatMap { [$0.from, $0.to, $0.why, $0.assertedBy, $0.state, $0.sources] }
            + evidence.flatMap { [$0.document, $0.locator, $0.quote] } + findings.flatMap { [$0.title, $0.decision, $0.history] }
            + openWork.flatMap { [$0.title, $0.reason] } + steps.flatMap { [$0.title, $0.state, $0.change] } + [money] + disclosures
            + references.map(\.provenance)
    }
}

public nonisolated enum CasePortablePackage {

    /// Links that make one item rest on another: selecting a record brings these neighbours with it (OUTPUT-03).
    static let dependencyTypes: Set<CaseMapLinkType> = [.supports, .challenges, .derivedFrom, .dependsOn, .receivedInResponseTo, .attributedTo,
                                                        .selectedForReport, .moneyFrom, .moneyTo]

    /// The items a selection covers, each with why it is in (nil: chosen; text: added as a dependency).
    public static func resolve(_ selection: CasePackageSelection, in p: CaseMapProjection, briefings: [CaseBriefing]) -> [CaseMapNodeID: String?] {
        var chosen: [CaseMapNodeID: String?] = [:]
        func branch(_ root: CaseMapNodeID) {
            guard p.node(root) != nil else { return }
            var queue = [root]
            chosen[root] = .some(nil)
            var isFrame = false
            while let cur = queue.popLast() {
                for l in p.links(of: cur) where l.type == .placedIn && l.from == cur {
                    isFrame = true
                    if chosen[l.to] == nil { chosen[l.to] = .some(nil); queue.append(l.to) }
                }
            }
            if !isFrame {
                for l in p.links(of: root) where l.type.drawable {
                    let other = l.from == root ? l.to : l.from
                    if chosen[other] == nil { chosen[other] = .some(nil) }
                }
            }
        }
        switch selection {
        case .wholeCase:
            for n in p.nodes where n.kind != .group { chosen[n.id] = .some(nil) }
            return chosen
        case .branch(let root):
            branch(root)
        case .briefing(let id):
            guard let b = briefings.first(where: { $0.id == id }) else { return [:] }
            for i in b.activeItems {
                guard let r = i.record else { continue }
                if i.kind == .frame { branch(r) } else if p.node(r) != nil { chosen[r] = .some(nil) }
            }
        case .records(let ids):
            for r in ids where p.node(r) != nil { chosen[r] = .some(nil) }
        }
        // Required dependencies: what each chosen item rests on, one step out.
        for id in Array(chosen.keys) {
            guard let n = p.node(id) else { continue }
            for l in p.links(of: id) where dependencyTypes.contains(l.type) {
                let other = l.from == id ? l.to : l.from
                if chosen[other] == nil, p.node(other) != nil { chosen[other] = .some("Included because “\(n.title)” rests on it (\(l.type.label)).") }
            }
        }
        return chosen
    }

    static func day(_ d: Date?) -> String { d.map { ISO8601DateFormatter.string(from: $0, timeZone: .gmt, formatOptions: [.withFullDate]) } ?? "" }

    /// Build the package's content: restricted items are left out (counted only), everything else in the selection is shown
    /// with its provenance, state and sources.
    public static func build(projection p: CaseMapProjection, selection: CasePackageSelection, briefings: [CaseBriefing], money: String,
                             header: [String]) -> CasePackageContent {
        let resolved = resolve(selection, in: p, briefings: briefings)
        let all = p.nodes.filter { $0.kind != .group }
        let restricted = all.filter { resolved[$0.id] != nil && $0.status.kind == .restricted }
        let included = all.filter { resolved[$0.id] != nil && $0.status.kind != .restricted }.sorted { $0.id < $1.id }
        var anchors: [CaseMapNodeID: String] = [:]
        for (i, n) in included.enumerated() { anchors[n.id] = "item-\(i + 1)" }
        // Evidence: every source behind an included item or link, once.
        var evidence: [CasePackageContent.Evidence] = []
        var evidenceAnchor: [String: String] = [:]
        var citations: [StudioEvidenceRef] = []
        var referenceInputs: [CasePackageContent.ReferenceInput] = []
        func evidenceRefs(_ refs: [CaseMapSourceRef], holder: String, provenance: String) -> String {
            refs.map { r -> String in
                let key = "\(r.sourceVersionID?.uuidString ?? "-")|\(r.blockID?.uuidString ?? "-")|\(r.quote ?? "")|\(r.documentName ?? "")"
                let a = evidenceAnchor[key] ?? "ev-\(evidence.count + 1)"
                referenceInputs.append(.init(holder: holder, anchor: a, provenance: provenance, source: r))
                if evidenceAnchor[key] != nil { return a }
                evidenceAnchor[key] = a
                evidence.append(.init(anchor: a, document: r.documentName ?? "A document", locator: r.locatorText, quote: r.quote ?? "",
                                      version: r.sourceVersionID?.uuidString ?? "no source version recorded"))
                if let v = r.sourceVersionID { citations.append(StudioEvidenceRef(sourceVersionID: v, objectID: r.objectID, quote: r.quote)) }
                return a
            }.joined(separator: " ")
        }
        var items: [CasePackageContent.Item] = []
        var findings: [CasePackageContent.Finding] = []
        var open: [CasePackageContent.OpenWork] = []
        var pinned: [String: String] = [:]
        for n in included {
            let a = anchors[n.id] ?? ""
            let prov = CasePackageProvenance.of(n)
            var dates: [String] = []
            if let r = n.recordedAt { dates.append("recorded \(day(r))") }
            if let tv = n.timeValue { dates.append("event \(tv.label())") }
            items.append(.init(anchor: a, key: n.id.key, kind: n.kind.label, title: n.title, wording: n.wording ?? "", provenance: prov.rawValue,
                               state: "\(n.status.kind.label): \(n.status.text)" + (n.qualifications.isEmpty ? "" : " · " + n.qualifications.joined(separator: " · ")),
                               review: n.review.label, dates: dates.joined(separator: " · "), sources: evidenceRefs(n.sources, holder: n.id.key, provenance: n.author?.label ?? "not recorded"),
                               addedBecause: (resolved[n.id] ?? nil) ?? "", revision: n.revision ?? ""))
            pinned[n.id.key] = n.revision ?? ""
            if [.finding, .hypothesis, .contradiction, .question].contains(n.kind) {
                findings.append(.init(itemAnchor: a, title: n.title, kind: n.kind.label, provenance: prov.rawValue, decision: n.review.label,
                                      history: n.history.joined(separator: " · ")))
            }
            let doneReviews: Set<CaseMapReviewState> = [.completed, .accepted, .dismissed, .withdrawn, .rejected]
            if n.kind == .action, !doneReviews.contains(n.review) {
                open.append(.init(itemAnchor: a, title: n.title, reason: "Open work — \(n.status.text)"))
            } else if prov == .unresolved {
                open.append(.init(itemAnchor: a, title: n.title, reason: n.review.awaitingReview ? n.review.label : "\(n.status.kind.label): \(n.status.text)"))
            }
        }
        let shown = Set(included.map(\.id))
        let links = p.links.filter { shown.contains($0.from) && shown.contains($0.to) && $0.status.kind != .restricted }
        let relations = links.map { l in
            CasePackageContent.Relation(fromAnchor: anchors[l.from] ?? "", from: p.node(l.from)?.title ?? "", type: l.type.label,
                                        toAnchor: anchors[l.to] ?? "", to: p.node(l.to)?.title ?? "", why: l.basis, assertedBy: l.assertedBy.label,
                                        provenance: CasePackageProvenance.of(l).rawValue, state: "\(l.status.kind.label): \(l.status.text) · \(l.review.label)",
                                        sources: evidenceRefs(l.sources, holder: "link:\(l.from.key)>\(l.to.key)", provenance: l.assertedBy.label))
        }
        // Disclosures (counts only; restricted content by count, never by title).
        var omitted: [String: Int] = [:]
        var disclosures: [String] = []
        let notSelected = all.filter { resolved[$0.id] == nil }
        if !notSelected.isEmpty {
            let byKind = Dictionary(grouping: notSelected, by: \.kind).map { "\($0.value.count) \($0.key.label.lowercased())" }.sorted()
            disclosures.append("Not selected for this package: \(notSelected.count) item(s) (\(byKind.joined(separator: ", "))).")
            omitted["notSelected"] = notSelected.count
        }
        if !restricted.isEmpty {
            disclosures.append("Restricted: \(restricted.count) item(s) in the selection are not included; nothing about them is shown.")
            omitted["restricted"] = restricted.count
        }
        let hiddenLinks = p.links.filter { (shown.contains($0.from) != shown.contains($0.to)) || (shown.contains($0.from) && shown.contains($0.to) && $0.status.kind == .restricted) }.count
        if hiddenLinks > 0 {
            disclosures.append("\(hiddenLinks) link(s) between an included item and one outside this package (or restricted) are not shown.")
            omitted["linksOutside"] = hiddenLinks
        }
        let unavailable = included.filter { $0.status.kind == .unavailable }.count
        if unavailable > 0 { disclosures.append("Source unavailable: \(unavailable) included item(s) cite a source no longer in the case; they are marked."); omitted["unavailable"] = unavailable }
        let unsupported = included.filter { $0.status.kind == .unsupported }.count
        if unsupported > 0 { disclosures.append("Not supported by a verified source: \(unsupported) included item(s); they are marked."); omitted["unsupported"] = unsupported }
        if p.danglingLinks > 0 { disclosures.append("\(p.danglingLinks) recorded link(s) point to an item no longer in the case."); omitted["dangling"] = p.danglingLinks }
        disclosures.append("Originals and derived files are not inside this package: it carries each source's document name, location and quoted words. Ask the sender for the documents themselves.")
        omitted["originals"] = evidence.count
        // Briefing steps.
        var steps: [CasePackageContent.Step] = []
        if case .briefing(let id) = selection, let b = briefings.first(where: { $0.id == id }) {
            steps = CaseBriefings.steps(b, in: p, viewName: { _ in nil }).map { .init(title: $0.title, state: $0.state, change: $0.change ?? "") }
        }
        // Citations unique by version + quote.
        var seen = Set<String>()
        citations = citations.filter { seen.insert("\($0.sourceVersionID?.uuidString ?? "")|\($0.quote ?? "")").inserted }
        var content = CasePackageContent(title: p.title, header: header, items: items, relations: relations, evidence: evidence, findings: findings, openWork: open,
                                         steps: steps, money: money, disclosures: disclosures, citations: citations, pinned: pinned, omitted: omitted)
        content.referenceInputs = referenceInputs
        return content
    }

    // MARK: HTML (static, read-only)

    /// Escape text for HTML content and attribute values: nothing a case contains can become markup.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:
                // Control characters (other than tab / newline) never reach the page.
                if ch.value < 0x20 && ch != "\n" && ch != "\t" { out += " " } else { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }

    static let csp = "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"

    static func anchorList(_ refs: String) -> String {
        refs.split(separator: " ").map { "<a href=\"#\(escape(String($0)))\">\(escape(String($0)))</a>" }.joined(separator: " ")
    }

    /// One static HTML file: contents, status, items, relationships, evidence, findings and decisions, open work, money,
    /// briefing steps, what is not included, and the manifest. Every link is a fragment inside the file.
    public static func html(_ c: CasePackageContent, status: String, manifestJSON: String) -> String {
        let e = escape
        var h = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="referrer" content="no-referrer">
        <title>Case package — \(e(c.title))</title>
        <style>body{font:14px -apple-system,Helvetica,sans-serif;margin:2em;max-width:70em}table{border-collapse:collapse;width:100%}td,th{border:1px solid #bbb;padding:4px;vertical-align:top;text-align:left}th{background:#eee}.status{border:2px solid #333;padding:8px;font-weight:600}.supplied{background:#eef6ee}.inferred{background:#fff7e6}.reviewed{background:#e8f0fb}.unresolved{background:#fdeaea}pre{white-space:pre-wrap}</style>
        </head><body>
        <h1>Case package — \(e(c.title))</h1>
        <nav id="contents" data-section="contents"><a href="#status">Status</a> · <a href="#legend">How to read this</a> · <a href="#items">Items</a> · <a href="#relationships">Relationships</a> · <a href="#evidence">Evidence</a> · <a href="#findings">Findings and decisions</a> · <a href="#open-work">Open work</a> · <a href="#money">Money</a> · <a href="#briefing">Briefing</a> · <a href="#references">References</a> · <a href="#disclosures">Not included</a> · <a href="#manifest">Manifest</a></nav>
        <section id="status" data-section="status"><h2>Status</h2><p class="status">\(e(status))</p>
        """
        for line in c.header { h += "<p>\(e(line))</p>\n" }
        h += "</section>\n<section id=\"legend\" data-section=\"legend\"><h2>How to read this</h2><table><tr><th>Mark</th><th>Meaning</th></tr>\n"
        for p in CasePackageProvenance.allCases { h += "<tr class=\"\(p.rawValue)\"><td>\(e(p.label))</td><td>\(e(p.meaning))</td></tr>\n" }
        h += "</table><p>This file is read-only: it runs no script and fetches nothing. Every link leads to another place in this file.</p></section>\n"
        h += "<section id=\"items\" data-section=\"items\"><h2>Items</h2><table><tr><th>Item</th><th>Kind</th><th>Mark</th><th>State</th><th>Review</th><th>Dates</th><th>Evidence</th></tr>\n"
        for i in c.items {
            h += "<tr id=\"\(e(i.anchor))\" data-row=\"item\" class=\"\(e(i.provenance))\"><td><strong>\(e(i.title))</strong>"
            if !i.wording.isEmpty, i.wording != i.title { h += "<br>\(e(i.wording))" }
            if !i.addedBecause.isEmpty { h += "<br><em>\(e(i.addedBecause))</em>" }
            h += "<br><small>\(e(i.key))\(i.revision.isEmpty ? "" : " · revision " + e(String(i.revision.prefix(16))))</small></td>"
            h += "<td>\(e(i.kind))</td><td>\(e(CasePackageProvenance(rawValue: i.provenance)?.label ?? i.provenance))</td><td>\(e(i.state))</td><td>\(e(i.review))</td><td>\(e(i.dates))</td><td>\(anchorList(i.sources))</td></tr>\n"
        }
        h += "</table></section>\n<section id=\"relationships\" data-section=\"relationships\"><h2>Relationships and their evidence</h2><table><tr><th>From</th><th>Relationship</th><th>To</th><th>Why this link exists</th><th>Asserted by</th><th>Mark</th><th>State</th><th>Evidence</th></tr>\n"
        for r in c.relations {
            h += "<tr data-row=\"link\" class=\"\(e(r.provenance))\"><td><a href=\"#\(e(r.fromAnchor))\">\(e(r.from))</a></td><td>\(e(r.type))</td><td><a href=\"#\(e(r.toAnchor))\">\(e(r.to))</a></td><td>\(e(r.why))</td><td>\(e(r.assertedBy))</td><td>\(e(CasePackageProvenance(rawValue: r.provenance)?.label ?? r.provenance))</td><td>\(e(r.state))</td><td>\(anchorList(r.sources))</td></tr>\n"
        }
        h += "</table></section>\n<section id=\"evidence\" data-section=\"evidence\"><h2>Evidence</h2><table><tr><th>Ref</th><th>Document</th><th>Where</th><th>Quoted words</th><th>Source version</th><th>Available now</th></tr>\n"
        for v in c.evidence {
            h += "<tr id=\"\(e(v.anchor))\" data-row=\"evidence\"><td>\(e(v.anchor))</td><td>\(e(v.document))</td><td>\(e(v.locator))</td><td>\(e(v.quote))</td><td><small>\(e(v.version))</small></td><td>\(e(v.availableNow))</td></tr>\n"
        }
        h += "</table></section>\n<section id=\"findings\" data-section=\"findings\"><h2>Findings and decisions</h2><table><tr><th>Item</th><th>Kind</th><th>Mark</th><th>Decision</th><th>History</th></tr>\n"
        for f in c.findings {
            h += "<tr data-row=\"finding\" class=\"\(e(f.provenance))\"><td><a href=\"#\(e(f.itemAnchor))\">\(e(f.title))</a></td><td>\(e(f.kind))</td><td>\(e(CasePackageProvenance(rawValue: f.provenance)?.label ?? f.provenance))</td><td>\(e(f.decision))</td><td>\(e(f.history))</td></tr>\n"
        }
        h += "</table></section>\n<section id=\"open-work\" data-section=\"open-work\"><h2>Open work and unresolved matters</h2><table><tr><th>Item</th><th>Why it is open</th></tr>\n"
        for o in c.openWork { h += "<tr data-row=\"open\"><td><a href=\"#\(e(o.itemAnchor))\">\(e(o.title))</a></td><td>\(e(o.reason))</td></tr>\n" }
        h += "</table></section>\n<section id=\"money\" data-section=\"money\"><h2>Money</h2><pre>\(e(c.money))</pre></section>\n"
        h += "<section id=\"briefing\" data-section=\"briefing\"><h2>Briefing</h2><table><tr><th>Step</th><th>State</th><th>Change</th></tr>\n"
        for s in c.steps { h += "<tr data-row=\"step\"><td>\(e(s.title))</td><td>\(e(s.state))</td><td>\(e(s.change))</td></tr>\n" }
        // S16 (ARCH-05) — every typed reference: who holds it, the object and exact version, where, available now, scope, asserted by.
        h += "</table></section>\n<section id=\"references\" data-section=\"references\"><h2>References</h2><table><tr><th>Cited by</th><th>Object</th><th>Version</th><th>Where</th><th>Available now</th><th>Scope checked</th><th>Asserted by</th></tr>\n"
        for r in c.references {
            let f = r.fields
            h += "<tr data-row=\"reference\">" + f.map { "<td>\(e($0))</td>" }.joined() + "</tr>\n"
        }
        h += "</table></section>\n<section id=\"disclosures\" data-section=\"disclosures\"><h2>Not included</h2><ul>\n"
        for d in c.disclosures { h += "<li data-row=\"disclosure\">\(e(d))</li>\n" }
        h += "</ul></section>\n<section id=\"manifest\" data-section=\"manifest\"><h2>Manifest</h2><pre id=\"manifest-json\">\(e(manifestJSON))</pre></section>\n</body></html>\n"
        return h
    }
}

// MARK: - Reader (OUTPUT-07 / OUTPUT-10): opens a package with nothing but its bytes

public nonisolated struct CasePortablePackageRead: Sendable, Equatable {
    public var sections: [String]
    public var rows: [String: Int]
    public var anchors: Set<String>
    public var links: [String]
    public var brokenAnchors: [String]
    /// Anything that could run or fetch (a script, an event handler, an external URL, an embedded frame).
    public var violations: [String]
    public var manifest: CaseOutputManifest?
    /// The visible text of a section (tags removed, entities decoded).
    public var sectionText: [String: String]
}

public nonisolated enum CasePortablePackageReader {
    /// Manifest count key → the data-row kind it counts.
    static let rowKinds: [String: String] = ["items": "item", "links": "link", "evidence": "evidence", "findings": "finding", "openWork": "open",
                                             "steps": "step", "disclosures": "disclosure", "references": "reference"]

    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Anything in the page that could run or fetch. S13 (PERF): the prepare check needs only this, not a whole read —
    /// a 57 MB stress package was read in full (every section's text rebuilt) just to look for active content.
    public static func violations(_ html: String) -> [String] {
        var violations: [String] = []
        let lower = html.lowercased()
        // Case text is escaped ("<" never survives), so markup tokens can only come from the page itself.
        for token in ["<script", "<iframe", "<object", "<embed", "<link", "<img", "<form", "<base", "<svg", "<audio", "<video"] where lower.contains(token) {
            violations.append(token)
        }
        // A tag holding "javascript:" means the page holds it: only then is every tag scanned (the same result, without
        // materialising every tag of a large package).
        if lower.contains("javascript:") {
            for tag in matches(#"<[^>]+>"#, html) where tag[0].lowercased().contains("javascript:") { violations.append("javascript: in \(tag[0].prefix(40))") }
        }
        for style in matches(#"<style[^>]*>([\s\S]*?)</style>"#, html) {
            let css = style[1].lowercased()
            if css.contains("@import") || css.contains("url(") { violations.append("a style that fetches") }
        }
        if !matches(#"<[^>]+\son[a-z]+\s*="#, html).isEmpty { violations.append("an event handler attribute") }
        if !matches(#"http-equiv\s*=\s*"refresh""#, html).isEmpty { violations.append("a refresh") }
        for m in matches(#"\s(?:href|src|action|srcset)\s*=\s*"([^"]*)""#, html) where !m[1].hasPrefix("#") {
            violations.append("a reference outside the file (\(m[1].prefix(40)))")
        }
        if !lower.contains("content-security-policy") || !lower.contains("script-src 'none'") { violations.append("no script-forbidding policy") }
        return violations
    }

    /// Read a package with nothing but its bytes. `sectionText: false` skips rebuilding each section's visible text (the
    /// read-back of a written file needs the rows, anchors and manifest only).
    public static func read(_ html: String, sectionText withText: Bool = true) -> CasePortablePackageRead {
        let violations = Self.violations(html)
        let sections = matches(#"data-section="([^"]+)""#, html).map { $0[1] }
        var rows: [String: Int] = [:]
        for m in matches(#"data-row="([^"]+)""#, html) { rows[m[1], default: 0] += 1 }
        let anchors = Set(matches(#"\sid="([^"]+)""#, html).map { $0[1] })
        let links = matches(##"href="#([^"]+)""##, html).map { unescape($0[1]) }
        let broken = links.filter { !anchors.contains($0) }
        var manifest: CaseOutputManifest?
        if let m = matches(#"<pre id="manifest-json">([\s\S]*?)</pre>"#, html).first { manifest = CaseOutputManifest.decode(unescape(m[1])) }
        var text: [String: String] = [:]
        for m in (withText ? matches(#"<section id="([^"]+)" data-section="[^"]+">([\s\S]*?)</section>"#, html) : []) {
            text[m[1]] = unescape(m[2].replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        return CasePortablePackageRead(sections: sections, rows: rows, anchors: anchors, links: links, brokenAnchors: broken, violations: violations,
                                       manifest: manifest, sectionText: text)
    }
}

// The service side (CaseOutputService: fences, approvals, products, external writers) is in CaseOutputService.swift, so
// its helpers stay private to the one output door.

// MARK: - Lifecycle (RECOVERY-10)

public nonisolated enum CaseLifecycleError: Error, Equatable, LocalizedError {
    case archiveNeedsClosed, alreadyArchived, notArchived, archivedCannotReopen
    public var errorDescription: String? {
        switch self {
        case .archiveNeedsClosed: return "Only a closed case is archived. Close the case first (with its rationale), then archive it."
        case .alreadyArchived: return "This case is already archived."
        case .notArchived: return "This case is not archived."
        case .archivedCannotReopen: return "This case is archived. Take it out of the archive first (Unarchive), then reopen it."
        }
    }
}

// MARK: - Closure position (OUTPUT-09)

/// Work the closing person waived, with why.
public nonisolated struct CaseWaivedWork: Codable, Sendable, Equatable {
    public var item: String
    public var reason: String
    public init(item: String, reason: String) { self.item = item; self.reason = reason }
}

public nonisolated struct CaseClosurePosition: Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let closureSequence: Int
    public let checkpointID: UUID?
    public let disposition: String
    public let dispositionAuthorizedBy: String
    public let waived: [CaseWaivedWork]
    public let unresolved: [String]
    public let recordedBy: String
    public let recordedAt: Date
}

public nonisolated enum CaseClosurePositionError: Error, Equatable, LocalizedError {
    case notClosed, blank(String), alreadyRecorded
    public var errorDescription: String? {
        switch self {
        case .notClosed: return "The closure position is recorded when the case is closed; this case is not closed."
        case .blank(let what): return "\(what) is required."
        case .alreadyRecorded: return "The position of this closure is already recorded; it is fixed. Reopen and close again to record a new one."
        }
    }
}

extension CaseHistoryService {
    /// OUTPUT-09 — record the closure's position: the case's recorded state at closure (a milestone checkpoint), the waived
    /// work with reasons, the disposition and who authorised it, beside the closure decision it belongs to. Reopening later
    /// keeps all of it (the record is fixed; a new closure gets its own).
    @discardableResult
    public func recordClosurePosition(caseID: UUID, disposition: String, authorizedBy: String, waived: [CaseWaivedWork], unresolved: [String],
                                      actor: String, at date: Date = Date()) async throws -> CaseClosurePosition {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .administer)
        let disp = disposition.trimmingCharacters(in: .whitespacesAndNewlines), auth = authorizedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !disp.isEmpty else { throw CaseClosurePositionError.blank("The disposition") }
        guard !auth.isEmpty else { throw CaseClosurePositionError.blank("Who authorised the disposition") }
        for w in waived where w.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CaseClosurePositionError.blank("A reason for waiving “\(w.item)”") }
        let seq = Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM investigation_case_closures WHERE case_id = ? AND decision = ?;",
                                               [.uuid(caseID), .text(ClosureDecisionKind.closed.rawValue)]).first?.int(0) ?? 0)
        let status = try await database.query("SELECT status FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.string(0)
        guard seq > 0, status == InvestigationCaseStatus.closed.rawValue else { throw CaseClosurePositionError.notClosed }
        let cp = try await record(caseID: caseID, kind: .milestone, name: "Closure \(seq)", actor: actor, at: date)
        let id = UUID()
        let waivedJSON = String(decoding: try JSONEncoder().encode(waived), as: UTF8.self)
        let unresolvedJSON = String(decoding: try JSONEncoder().encode(unresolved), as: UTF8.self)
        let file = CaseFileRepository(database: database)
        try await file.write("co_close", caseID: caseID, actor: actor, action: "closurePositionRecorded", detail: "Closure \(seq): \(disp)", at: date,
                             allowedWhenClosed: true) { db in
            guard try db.query("SELECT 1 FROM case_closure_records WHERE case_id = ? AND closure_sequence = ?;", [.uuid(caseID), .integer(Int64(seq))]).isEmpty else {
                throw CaseClosurePositionError.alreadyRecorded
            }
            try db.exec("""
                INSERT INTO case_closure_records (id, case_id, closure_sequence, checkpoint_id, disposition, disposition_authorized_by, waived_json, unresolved_json, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .integer(Int64(seq)), .uuid(cp.id), .text(disp), .text(auth), .text(waivedJSON), .text(unresolvedJSON),
                      .text(actor), .date(date)])
        }
        guard let out = try await closurePositions(caseID: caseID).first(where: { $0.id == id }) else { throw CaseClosurePositionError.notClosed }
        return out
    }

    /// Every recorded closure position, oldest first.
    public func closurePositions(caseID: UUID) async throws -> [CaseClosurePosition] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, closure_sequence, checkpoint_id, disposition, disposition_authorized_by, waived_json, unresolved_json, recorded_by, recorded_at
            FROM case_closure_records WHERE case_id = ? ORDER BY closure_sequence;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let d = r.string(4), let a = r.string(5), let by = r.string(8), let at = r.date(9) else { return nil }
            let waived = (try? JSONDecoder().decode([CaseWaivedWork].self, from: Data((r.string(6) ?? "[]").utf8))) ?? []
            let unresolved = (try? JSONDecoder().decode([String].self, from: Data((r.string(7) ?? "[]").utf8))) ?? []
            return CaseClosurePosition(id: id, caseID: c, closureSequence: Int(r.int(2) ?? 0), checkpointID: r.uuid(3), disposition: d,
                                       dispositionAuthorizedBy: a, waived: waived, unresolved: unresolved, recordedBy: by, recordedAt: at)
        }
    }
}
