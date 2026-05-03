// VideoDisplayName.swift
// V5 — Single source of truth for the user-facing label of an imported
// video. We never show `originalFilename` directly because Photos asset
// names (IMG_1234.MOV, screen recordings, share-extension imports with
// UUID-derived names) range from ugly to unintelligible.
//
// Derived purely from `importedAt`, which is always populated:
//   • Today        → "Today, 2:45 PM"
//   • Yesterday    → "Yesterday, 9:14 AM"
//   • This year    → "May 2, 2:45 PM"
//   • Older        → "Mar 14, 2025, 9:14 AM"
//
// Use everywhere the UI references a source video by name.

import Foundation

extension ImportedVideo {
    /// Friendly name for display anywhere a user sees this video.
    /// Format depends on how recent the import is — recent videos get
    /// the relative ("Today" / "Yesterday") prefix so the home screen
    /// reads naturally; older videos fall back to a dated form.
    var displayName: String {
        let cal = Calendar.current
        let date = importedAt
        let timePart = date.formatted(date: .omitted, time: .shortened)

        if cal.isDateInToday(date) {
            return "Today, \(timePart)"
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday, \(timePart)"
        }
        let now = Date()
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }
}
