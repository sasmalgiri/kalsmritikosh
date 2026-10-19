//
//  NameKindCorrector.swift
//  Kalsmritikosh
//
//  Corrects the kind the name tagger gave a name when the name itself says otherwise.
//
//  FOUND BY THE CASE BENCH, 2026-10-18 (NTSB accident reports): the tagger filed aircraft makers
//  as people ("person:Piper" from "a Piper PA 28-180"), airports as people ("person:Wiley Post
//  Airport") and police departments as places. A subject dossier of "Piper" the person is wrong
//  evidence, not noise, so the name is RE-TYPED, never dropped (no extracted data is deleted).
//
//  Only strong signals change a kind:
//   - the name's LAST word is a facility/place noun → location ("… Airport", "… County");
//   - the name's last word is an organisation noun → organisation ("… Department", "… Corp");
//   - the name is followed at once by a model code → organisation, the maker ("Piper PA 28-180",
//     "Cessna 182B", "Boeing 737-300").
//  A one-word name never changes kind by its last word ("Field", "Bank" are surnames too).
//
//  Deterministic, offline.
//

import Foundation

public enum NameKindCorrector {

    nonisolated static let placeHeads: Set<String> = [
        "airport", "airfield", "airstrip", "heliport", "county", "parish", "park", "river", "lake",
        "mountain", "beach", "island", "harbor", "harbour", "bay", "valley", "canyon", "creek",
    ]
    nonisolated static let organisationHeads: Set<String> = [
        "department", "police", "hospital", "university", "college", "school", "company", "corporation",
        "corp", "inc", "llc", "ltd", "bank", "board", "commission", "court", "agency", "administration",
        "association", "authority", "airlines", "airways", "aviation", "services", "group", "council",
        "ministry", "office", "institute", "foundation", "church", "clinic",
    ]

    /// "PA 28-180", "182B", "737-300", "T210G", "PC-12": a model designation.
    nonisolated static let modelCode = try? NSRegularExpression(
        // A letter prefix ("PA 28-180", "T210G"), a letter suffix ("182B") or a hyphenated pair
        // ("737-300") — a bare number ("42 years old") is not a model.
        pattern: #"^\s{1,2}(?:[A-Z]{1,3}[- ]?\d{2,4}[A-Z0-9]*(?:-\d{1,4}[A-Z0-9]*)?|\d{2,4}[A-Z]+[A-Z0-9]*|\d{2,4}-\d{1,4}[A-Z0-9]*)\b"#)

    /// The corrected kind for a tagged name, or the tagged kind when nothing says otherwise.
    /// `following` is the text right after the name in the document (a few dozen characters).
    public nonisolated static func kind(for name: String, tagged: Entity.Kind, following: Substring) -> Entity.Kind {
        guard tagged == .person || tagged == .location || tagged == .organization else { return tagged }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        if words.count >= 2, let last = words.last {
            if placeHeads.contains(last) { return .location }
            if organisationHeads.contains(last) { return .organization }
        }
        if tagged == .person, let re = modelCode {
            let s = String(following.prefix(24))
            if re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
                return .organization
            }
        }
        return tagged
    }
}
