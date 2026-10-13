//
//  NameSuggester.swift
//  Billify
//
//  Live autocomplete for buyer/product names: given what's typed so far and
//  the full list of saved names (MemoryStore.products / .buyers), return the
//  matches to offer as tappable suggestions.
//
//  One small filter function, deliberately shared by both places names are
//  typed — the chat composer (while Billify waits on a buyer/product name)
//  and the Products & Buyers add/edit forms (under the Name field) — so a
//  saved entry gets picked instead of a near-duplicate being created.
//
//  Matching is a case-insensitive prefix match on the trimmed input ("Ra"
//  matches "Radhika Mills", "Raja Textiles", …), sorted A→Z, capped at a
//  handful of results so the suggestion row stays a quick pick rather than
//  a scrollable list.
//

import Foundation

enum NameSuggester {

    /// Upper bound on suggestions offered at once.
    static let suggestionLimit = 6

    /// Saved names whose lowercased form starts with the typed text,
    /// alphabetically (A→Z, case-insensitive).
    ///
    /// An exact (case-insensitive) match is excluded: tapping it would be a
    /// no-op, and hiding the row once the full name is typed is the natural
    /// "selection made" signal — which is also what makes the form variant
    /// disappear the moment an exact saved name is entered.
    static func suggestions(for typedText: String, in names: [String]) -> [String] {
        let query = typedText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let matches = names.filter { name in
            let candidate = name.lowercased()
            return candidate.hasPrefix(query) && candidate != query
        }
        return Array(matches
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(suggestionLimit))
    }
}
