//
//  MaturationNotifier.swift
//  Kalsmritikosh
//
//  Posts a UserNotification when a previously-asked subject's memory
//  has matured — i.e. the Tier-3 distillation just produced a new
//  MemoryObject for it, which means any prior answer about that
//  subject would now read differently. The user gets a tappable
//  banner that takes them back to AskView with the question re-run.
//
//  Privacy: notifications never include the document content, just
//  the subject identifier (e.g. "Project Delta", "Khurana and
//  Khurana"). The user already knows what they asked about.
//

import Foundation
import OSLog
#if canImport(UserNotifications)
import UserNotifications
#endif

public actor MaturationNotifier {
    private static let log = Logger(subsystem: "kalsmritikosh", category: "MaturationNotifier")

    /// Recent question subjects, used to gate notifications. We only
    /// fire when an invalidated subject matches something the user
    /// has actually asked about recently — otherwise the user gets a
    /// flood of "memory updated for X" toasts during bulk ingest.
    private var recentQuestionSubjects: Set<String> = []
    private let maxRecent = 32

    /// Has the user granted notification permission yet?
    private var authorized: Bool = false
    private var requestedAuthorization: Bool = false

    public init() {}

    /// Record a subject the user just asked about. Called by AppState
    /// each time MasterBrain.answer resolves an intent to a subject
    /// (project/org/person/email/etc.). Subjects are stored
    /// case-folded so "Khurana" and "khurana" match.
    public func registerQuestion(subject: String) {
        let normalized = subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        recentQuestionSubjects.insert(normalized)
        // Tiny ring-buffer behavior — when we'd grow past the cap,
        // drop the oldest by rebuilding. Set has no order, but the
        // user-experience cost of forgetting one stale question is
        // far smaller than ignoring a real one because we hit a cap.
        if recentQuestionSubjects.count > maxRecent {
            recentQuestionSubjects = Set(recentQuestionSubjects.shuffled().prefix(maxRecent))
        }
    }

    /// Called by IncrementalUpdater after a successful Tier-3
    /// distillation. Fires a notification iff the subject was in
    /// `recentQuestionSubjects` AND the user has granted
    /// notification permission.
    public func notifyIfRelevant(
        subjectKind: String,
        subjectIdentifier: String
    ) async {
        let normalized = subjectIdentifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard recentQuestionSubjects.contains(normalized) else { return }
        await fire(kind: subjectKind, identifier: subjectIdentifier)
    }

    /// Drop the gate and notify unconditionally — useful for the
    /// "force re-run" path from a debug menu.
    public func notifyAlways(
        subjectKind: String,
        subjectIdentifier: String
    ) async {
        await fire(kind: subjectKind, identifier: subjectIdentifier)
    }

    /// Resets the recent-questions set. Hook for "stop watching me"
    /// privacy settings.
    public func reset() {
        recentQuestionSubjects.removeAll()
    }

    // MARK: - UserNotifications plumbing

    private func ensureAuthorized() async -> Bool {
        #if canImport(UserNotifications)
        if authorized { return true }
        if requestedAuthorization { return authorized }
        requestedAuthorization = true
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorized = granted
            return granted
        } catch {
            Self.log.warning("Notification authorization failed: \(String(describing: error), privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }

    private func fire(kind: String, identifier: String) async {
        #if canImport(UserNotifications)
        guard await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Answer matured"
        content.body = "New information about \(identifier) is now in the ledger. Tap to re-ask."
        content.userInfo = [
            "kind": kind,
            "identifier": identifier
        ]
        let request = UNNotificationRequest(
            identifier: "maturation-\(kind)-\(identifier)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.log.warning("Failed to post maturation notification: \(String(describing: error), privacy: .public)")
        }
        #else
        _ = (kind, identifier)
        #endif
    }
}
