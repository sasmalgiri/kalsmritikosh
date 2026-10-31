//
//  DisabledReason.swift
//  Kalsmritikosh
//
//  §6.9 — a disabled action always carries an intelligible reason and a direct remedy, readable by hover
//  and by VoiceOver; an empty screen says which of the five things is true (no files, unreadable files,
//  files outside the case scope, insufficient evidence, pending review, blocked export) and offers the
//  next step. Shared so screens do not each invent their own wording.
//

import SwiftUI

public extension View {
    /// Disable the control while `reason` is non-nil, and say why and what to do: as the tooltip, as the
    /// accessibility value and hint. With `reason == nil` the view is unchanged.
    @ViewBuilder
    func disabled(reason: String?, remedy: String? = nil) -> some View {
        if let reason {
            let text = remedy.map { "\(reason) \($0)" } ?? reason
            self.disabled(true)
                .help(text)
                .accessibilityValue("Unavailable: \(reason)")
                .accessibilityHint(remedy ?? "")
        } else {
            self
        }
    }
}

/// The five (plus one) reasons a screen can be empty, each with its own words and next step.
public nonisolated enum EmptyStateKind: Sendable, Equatable {
    case noFiles
    case unreadableFiles(count: Int)
    case outsideScope(available: Int)
    case insufficientEvidence
    case pendingReview(count: Int)
    case blockedExport(reason: String)

    public var title: String {
        switch self {
        case .noFiles: return "No documents yet"
        case .unreadableFiles: return "Documents added, but none could be read"
        case .outsideScope: return "Documents exist, but none are in this case’s scope"
        case .insufficientEvidence: return "The evidence does not settle this"
        case .pendingReview: return "Results are waiting for your review"
        case .blockedExport: return "Export is blocked"
        }
    }

    public var message: String {
        switch self {
        case .noFiles:
            return "Add a folder in Sources. Files are read where they are; nothing is moved or copied."
        case .unreadableFiles(let n):
            return "\(n) file\(n == 1 ? "" : "s") failed to read — see Needs attention in Sources for each reason (format kept but not read, password, corrupt file, scan without text)."
        case .outsideScope(let n):
            return "\(n) document\(n == 1 ? " is" : "s are") in the workspace but not in this case. Press “Add documents to this case” and confirm the scope preview."
        case .insufficientEvidence:
            return "No passage in the documents in scope supports an answer. Nothing is guessed; the closest passages are shown so you can judge, and Missing Proof lists what would settle it."
        case .pendingReview(let n):
            return "\(n) result\(n == 1 ? "" : "s") must be reviewed and saved before they count or can be carried into the report."
        case .blockedExport(let reason):
            return "\(reason) Nothing was written."
        }
    }

    public var symbol: String {
        switch self {
        case .noFiles: return "folder.badge.plus"
        case .unreadableFiles: return "doc.badge.ellipsis"
        case .outsideScope: return "scope"
        case .insufficientEvidence: return "questionmark.folder"
        case .pendingReview: return "checklist"
        case .blockedExport: return "lock.doc"
        }
    }

    public var remedy: (title: String, destination: Destination)? {
        switch self {
        case .noFiles, .unreadableFiles: return ("Open Sources", .sources)
        case .outsideScope: return ("Open Professional Jobs", .work)
        case .insufficientEvidence: return ("Open Findings ▸ Missing Proof", .findings)
        case .pendingReview: return ("Open Review", .review)
        case .blockedExport: return nil
        }
    }
}

/// The shared empty state: which of the reasons is true, and the way out.
public struct EmptyStateView: View {
    let kind: EmptyStateKind
    var detail: String? = nil

    public init(_ kind: EmptyStateKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    public var body: some View {
        ContentUnavailableView {
            Label(kind.title, systemImage: kind.symbol)
        } description: {
            VStack(spacing: 4) {
                Text(kind.message)
                if let detail { Text(detail).font(.caption) }
            }
        } actions: {
            if let remedy = kind.remedy {
                Button(remedy.title) { SurfaceOpener.open(remedy.destination) }
                    .accessibilityIdentifier("empty.remedy")
            }
        }
        .accessibilityIdentifier("empty.\(kindID)")
    }

    private var kindID: String {
        switch kind {
        case .noFiles: return "noFiles"
        case .unreadableFiles: return "unreadableFiles"
        case .outsideScope: return "outsideScope"
        case .insufficientEvidence: return "insufficientEvidence"
        case .pendingReview: return "pendingReview"
        case .blockedExport: return "blockedExport"
        }
    }
}
