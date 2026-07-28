//
//  TimelineStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006B — Evidence and Analytical Step Executors.
//  Handles the `timeline` step kind.
//
//  Entries are built from canonical references — exact event/claim/evidence IDs are
//  preserved, temporal precision and uncertainty travel with each entry, and undated
//  or conflicting-date entries are labelled explicitly. Canonical event dates are
//  NEVER mutated and missing dates are NEVER invented: an entry with no date is
//  undated, and an entry with conflicting candidate dates carries all candidates
//  and no resolved date. Alternative orderings are proposal-layer scenario overlays.
//  Commands: addEntry, removeEntry, addOverlay, removeOverlay, complete.
//

import Foundation

// MARK: - Conflicting date candidate

/// One candidate date for an entry whose sources disagree. All candidates are kept —
/// conflicts are surfaced, never averaged away.
public nonisolated struct WorkflowTimelineDateCandidate: Codable, Sendable, Equatable {
    public let dateISO8601: String
    public let precision: DatePrecision
    public let sourceNote: String

    public nonisolated init(dateISO8601: String, precision: DatePrecision, sourceNote: String) {
        self.dateISO8601 = dateISO8601
        self.precision = precision
        self.sourceNote = sourceNote
    }
}

// MARK: - Timeline entry

public nonisolated struct WorkflowTimelineEntry: Codable, Sendable, Equatable {
    public let id: UUID
    public let objectKind: WorkflowEvidenceObjectKind
    public let canonicalObjectID: String
    public let label: String
    /// Resolved date — nil when the entry is undated OR carries conflicting candidates.
    public let dateISO8601: String?
    /// Precision must accompany a resolved date; nil otherwise.
    public let datePrecision: DatePrecision?
    public let uncertaintyNote: String?
    /// Explicit label: true when the entry has no resolved date and no conflict set.
    public let isUndated: Bool
    /// Explicit label: true when conflicting candidate dates are recorded.
    public let hasDateConflict: Bool
    public let conflictingDates: [WorkflowTimelineDateCandidate]

    public nonisolated init(
        id: UUID,
        objectKind: WorkflowEvidenceObjectKind,
        canonicalObjectID: String,
        label: String,
        dateISO8601: String?,
        datePrecision: DatePrecision?,
        uncertaintyNote: String?,
        isUndated: Bool,
        hasDateConflict: Bool,
        conflictingDates: [WorkflowTimelineDateCandidate]
    ) {
        self.id = id
        self.objectKind = objectKind
        self.canonicalObjectID = canonicalObjectID
        self.label = label
        self.dateISO8601 = dateISO8601
        self.datePrecision = datePrecision
        self.uncertaintyNote = uncertaintyNote
        self.isUndated = isUndated
        self.hasDateConflict = hasDateConflict
        self.conflictingDates = conflictingDates
    }
}

// MARK: - Scenario overlay

/// A workflow-owned alternative ordering — proposal-layer state that never touches
/// canonical dates.
public nonisolated struct WorkflowTimelineScenarioOverlay: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let orderedEntryIDs: [UUID]

    public nonisolated init(id: UUID, name: String, orderedEntryIDs: [UUID]) {
        self.id = id
        self.name = name
        self.orderedEntryIDs = orderedEntryIDs
    }
}

// MARK: - State

public nonisolated struct TimelineStepState: Codable, Sendable {
    public var entries: [WorkflowTimelineEntry]
    public var overlays: [WorkflowTimelineScenarioOverlay]

    public nonisolated init(
        entries: [WorkflowTimelineEntry] = [],
        overlays: [WorkflowTimelineScenarioOverlay] = []
    ) {
        self.entries = entries
        self.overlays = overlays
    }
}

// MARK: - Command

public enum TimelineStepCommand: Sendable, Equatable {
    case addEntry(
        objectKind: WorkflowEvidenceObjectKind,
        canonicalObjectID: String,
        label: String,
        dateISO8601: String?,
        datePrecision: DatePrecision?,
        uncertaintyNote: String?,
        conflictingDates: [WorkflowTimelineDateCandidate]
    )
    case removeEntry(entryID: UUID)
    case addOverlay(name: String, orderedEntryIDs: [UUID])
    case removeOverlay(overlayID: UUID)
    case complete
}

extension TimelineStepCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, objectKind, canonicalObjectID, label, dateISO8601, datePrecision
        case uncertaintyNote, conflictingDates, entryID, name, orderedEntryIDs, overlayID
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "addEntry":
            self = .addEntry(
                objectKind: try c.decode(WorkflowEvidenceObjectKind.self, forKey: .objectKind),
                canonicalObjectID: try c.decode(String.self, forKey: .canonicalObjectID),
                label: try c.decode(String.self, forKey: .label),
                dateISO8601: try c.decodeIfPresent(String.self, forKey: .dateISO8601),
                datePrecision: try c.decodeIfPresent(DatePrecision.self, forKey: .datePrecision),
                uncertaintyNote: try c.decodeIfPresent(String.self, forKey: .uncertaintyNote),
                conflictingDates: try c.decodeIfPresent(
                    [WorkflowTimelineDateCandidate].self, forKey: .conflictingDates) ?? []
            )
        case "removeEntry":
            self = .removeEntry(entryID: try c.decode(UUID.self, forKey: .entryID))
        case "addOverlay":
            self = .addOverlay(
                name: try c.decode(String.self, forKey: .name),
                orderedEntryIDs: try c.decode([UUID].self, forKey: .orderedEntryIDs)
            )
        case "removeOverlay":
            self = .removeOverlay(overlayID: try c.decode(UUID.self, forKey: .overlayID))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addEntry(let objectKind, let canonicalObjectID, let label, let dateISO8601,
                       let datePrecision, let uncertaintyNote, let conflictingDates):
            try c.encode("addEntry", forKey: .type)
            try c.encode(objectKind, forKey: .objectKind)
            try c.encode(canonicalObjectID, forKey: .canonicalObjectID)
            try c.encode(label, forKey: .label)
            if let dateISO8601 = dateISO8601 { try c.encode(dateISO8601, forKey: .dateISO8601) }
            if let datePrecision = datePrecision { try c.encode(datePrecision, forKey: .datePrecision) }
            if let uncertaintyNote = uncertaintyNote { try c.encode(uncertaintyNote, forKey: .uncertaintyNote) }
            try c.encode(conflictingDates, forKey: .conflictingDates)
        case .removeEntry(let entryID):
            try c.encode("removeEntry", forKey: .type)
            try c.encode(entryID, forKey: .entryID)
        case .addOverlay(let name, let orderedEntryIDs):
            try c.encode("addOverlay", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(orderedEntryIDs, forKey: .orderedEntryIDs)
        case .removeOverlay(let overlayID):
            try c.encode("removeOverlay", forKey: .type)
            try c.encode(overlayID, forKey: .overlayID)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct TimelineStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.timeline"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .timeline

    private let gate: any WorkflowEvidenceReferenceGating

    public nonisolated init(gate: any WorkflowEvidenceReferenceGating) {
        self.gate = gate
    }

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: TimelineStepState(), stepKind: handledKind)
        return WorkflowStepPreparationResult(
            inputJSON: "{}", stateJSON: json, stateSHA256: sha,
            executorID: executorID, executorVersion: executorVersion
        )
    }

    public func execute(
        context: WorkflowStepExecutionContext,
        commandJSON: String
    ) async throws -> WorkflowStepExecutionResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        var state = try decodeCurrentState(TimelineStepState.self, from: context.stepRun)
        let command: TimelineStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(TimelineStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .addEntry(let objectKind, let canonicalObjectID, let label, let dateISO8601,
                       let datePrecision, let uncertaintyNote, let conflictingDates):
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "label", reason: "Entry label must not be blank"
                )
            }
            guard let objectUUID = UUID(uuidString: canonicalObjectID) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "canonicalObjectID", reason: "Not a valid canonical object UUID"
                )
            }
            // Conflict rules: a conflict needs >= 2 candidates and forbids a resolved date.
            if !conflictingDates.isEmpty {
                guard conflictingDates.count >= 2 else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "conflictingDates",
                        reason: "A date conflict requires at least two candidate dates"
                    )
                }
                guard dateISO8601 == nil, datePrecision == nil else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "dateISO8601",
                        reason: "A conflicting-date entry must not carry a resolved date"
                    )
                }
            }
            // Precision travels with the date — never one without the other.
            if dateISO8601 != nil, datePrecision == nil {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "datePrecision", reason: "A dated entry must declare its precision"
                )
            }
            if dateISO8601 == nil, datePrecision != nil {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "datePrecision", reason: "Precision without a date is not allowed"
                )
            }
            let verdict = await gate.verdict(
                kind: objectKind,
                canonicalObjectID: objectUUID,
                workspaceID: context.aggregate.run.workspaceID
            )
            guard case .permitted = verdict else {
                if case .denied(let why) = verdict {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "canonicalObjectID", reason: why
                    )
                }
                throw WorkflowStepExecutionError.validationFailed(
                    field: "canonicalObjectID", reason: "Reference denied"
                )
            }
            let hasConflict = !conflictingDates.isEmpty
            state.entries.append(WorkflowTimelineEntry(
                id: UUID(),
                objectKind: objectKind,
                canonicalObjectID: objectUUID.uuidString,
                label: trimmedLabel,
                dateISO8601: dateISO8601,
                datePrecision: datePrecision,
                uncertaintyNote: uncertaintyNote,
                isUndated: dateISO8601 == nil && !hasConflict,
                hasDateConflict: hasConflict,
                conflictingDates: conflictingDates
            ))
            return try save()

        case .removeEntry(let entryID):
            guard state.entries.contains(where: { $0.id == entryID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "entryID", reason: "No timeline entry with this ID"
                )
            }
            state.entries.removeAll { $0.id == entryID }
            // Overlays referencing the removed entry are dropped — they are proposal-layer.
            state.overlays.removeAll { $0.orderedEntryIDs.contains(entryID) }
            return try save()

        case .addOverlay(let name, let orderedEntryIDs):
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "name", reason: "Overlay name must not be blank"
                )
            }
            let entryIDs = Set(state.entries.map { $0.id })
            let unknown = orderedEntryIDs.filter { !entryIDs.contains($0) }
            guard unknown.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "orderedEntryIDs",
                    reason: "Overlay references unknown entry ID(s)"
                )
            }
            guard Set(orderedEntryIDs).count == orderedEntryIDs.count else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "orderedEntryIDs", reason: "Overlay ordering contains duplicates"
                )
            }
            state.overlays.append(WorkflowTimelineScenarioOverlay(
                id: UUID(), name: trimmedName, orderedEntryIDs: orderedEntryIDs
            ))
            return try save()

        case .removeOverlay(let overlayID):
            guard state.overlays.contains(where: { $0.id == overlayID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "overlayID", reason: "No overlay with this ID"
                )
            }
            state.overlays.removeAll { $0.id == overlayID }
            return try save()

        case .complete:
            guard !state.entries.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "Timeline must have at least one entry"
                )
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared"
                )
            }
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(.label(firstTransition.label))
            )
        }
    }
}
