//
//  SensitiveScopeMutationService.swift
//  Kalsmritikosh
//
//  OPS-003D.1.2 — single production path for all SensitiveScope assignment and
//  revocation mutations. Every successful mutation increments `revisionCount` and
//  yields on `policyChanges` so AppState can bump `sensitiveScopeRevision`, which
//  in turn re-fires the `.task(id:)` in SourceViewer, EvidenceViewer, and
//  EventDetailSheet. A failed mutation (e.g. `assignmentNotFound`) does not
//  increment — the architecture guard (`ci/guards/sensitive-scope-mutation-bypass.sh`)
//  prevents production code from bypassing this service and calling the repository
//  directly.
//

import Foundation

public actor SensitiveScopeMutationService {

    private let repository: SensitiveScopeRepository
    private let continuation: AsyncStream<Void>.Continuation

    /// Yields `()` after every successful assign or revoke. Observe this on the
    /// MainActor (via `for await _ in svc.policyChanges`) to drive
    /// `AppState.notifyScopePolicyChanged()` and trigger viewer revalidation.
    public nonisolated let policyChanges: AsyncStream<Void>

    /// Monotonically increasing count of successful mutations since init.
    /// Read with `await` from tests to verify increment behaviour without
    /// needing an AppState setup.
    public private(set) var revisionCount: Int = 0

    public init(repository: SensitiveScopeRepository) {
        let (stream, cont) = AsyncStream<Void>.makeStream()
        self.repository = repository
        self.policyChanges = stream
        self.continuation = cont
    }

    // MARK: - Assign

    /// Create a new sensitive-scope assignment. Increments `revisionCount` and
    /// signals `policyChanges` only when the repository transaction commits
    /// successfully. Any throw from the repository leaves the counter unchanged.
    @discardableResult
    public func assign(
        target: SensitiveScopeTarget,
        sensitivity: SensitivityLevel,
        authority: AssignmentAuthority,
        reason: String?,
        at date: Date
    ) async throws -> SensitiveScopeAssignment {
        let result = try await repository.assign(
            target: target,
            sensitivity: sensitivity,
            authority: authority,
            reason: reason,
            at: date)
        revisionCount += 1
        continuation.yield(())
        return result
    }

    // MARK: - Revoke

    /// Revoke an existing assignment. Increments `revisionCount` and signals
    /// `policyChanges` only on success. Throws (without incrementing) if the
    /// assignment is not found or already revoked.
    public func revoke(
        assignmentID: UUID,
        revokedBy: String,
        reason: String?,
        at date: Date
    ) async throws {
        try await repository.revoke(
            assignmentID: assignmentID,
            revokedBy: revokedBy,
            reason: reason,
            at: date)
        revisionCount += 1
        continuation.yield(())
    }
}
