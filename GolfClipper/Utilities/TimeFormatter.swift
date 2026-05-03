// TimeFormatter.swift
// Format seconds as "M:SS" or "M:SS.ss" for display in the UI.
// Also hosts ByteFormatter (V1.7) for human-readable file sizes.

import Foundation

enum TimeFormatter {
    /// Format a duration in seconds as "M:SS".
    static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Format a timestamp with a tenths place, e.g. "0:12.4".
    static func mmssTenths(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let m = Int(seconds) / 60
        let s = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%04.1f", m, s)
    }

    /// Compact duration label, e.g. "5.0s".
    static func seconds(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }
}

/// Human-readable byte sizes, e.g. "248 MB", "1.2 GB".
enum ByteFormatter {
    /// Best-effort human format. Uses ByteCountFormatter so units, locale,
    /// and rounding match what iOS shows everywhere else (Settings → Storage,
    /// Files app, etc.).
    static func human(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Convenience for optional sizes — returns nil when we don't know.
    static func human(_ bytes: Int64?) -> String? {
        guard let b = bytes else { return nil }
        return human(b)
    }
}
