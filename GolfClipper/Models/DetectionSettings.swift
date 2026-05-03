// DetectionSettings.swift
// User-tunable settings for how we detect golf-swing impacts and cut clips.
// These are persisted to JSON so changes survive app launches.
//
// V3 — energy-ratio detector with adaptive thresholding:
//  - The detector now computes per-window RMS energy via vDSP,
//    then a "ratio" of current window / mean of previous 10 windows,
//    then thresholds on `median(ratios) + N × stddev(ratios)`.
//  - The preset's contribution is now a single `detectionMultiplier`
//    (= the N in that formula). Higher = stricter.
//  - User can override the multiplier in Settings → Debug for tuning.
//  - The old V1.7 preset thresholds (minPeakAmplitude / minPNR /
//    minSharpness / minConfidence) are gone; the forgiving decoder
//    silently drops them from old persisted settings.json files.

import Foundation

/// Detection sensitivity preset. Each preset bundles the threshold
/// multiplier the energy-ratio detector applies to the standard-deviation
/// formula `threshold = median(ratios) + multiplier × stddev(ratios)`.
///
/// • `catchMore`   — finds more possible swings, but may include extra clips.
/// • `recommended` — fewer false clips. Best for most videos.
enum DetectionPreset: String, Codable, CaseIterable, Identifiable {
    case catchMore
    case recommended

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .catchMore:   return "Catch More"
        case .recommended: return "Recommended"
        }
    }

    var summary: String {
        switch self {
        case .catchMore:
            return "Finds more possible shots, but may include extra clips."
        case .recommended:
            return "Fewer false clips. Best for most videos."
        }
    }

    /// N in `threshold = median(ratios) + N × stddev(ratios)`.
    /// Higher = stricter (fewer impacts). V3.7 production-tuned defaults.
    var detectionMultiplier: Double {
        switch self {
        case .catchMore:   return 2.0
        case .recommended: return 5.0
        }
    }
}

struct DetectionSettings: Codable, Equatable {
    /// Seconds BEFORE the detected impact to keep in the clip.
    var preImpactSeconds: Double = 2.5

    /// Seconds AFTER the detected impact to keep in the clip.
    var postImpactSeconds: Double = 2.5

    /// Detection sensitivity preset (see `DetectionPreset`). Default
    /// is Recommended for V1: prioritize clean ball-contact clips
    /// over recall. Missed swings can still be saved with Manual Clip.
    var preset: DetectionPreset = .recommended

    /// Optional override of the preset's multiplier. nil = use the
    /// preset's value. Settings → Debug exposes a slider that sets this.
    var detectionMultiplierOverride: Double?

    /// Minimum spacing between two accepted impacts (seconds).
    /// Default 6.0: typical range cadence is ≥ 8s, so 6s safely
    /// separates real swings without merging them.
    var minimumSpacingSeconds: Double = 6.0

    // MARK: - V3.5 — motion validation (frame-diff filter for false positives)

    /// Run motion validation as a second pass after audio detection.
    /// When false, every audio candidate becomes a clip (V3 behaviour).
    var motionValidationEnabled: Bool = true

    /// V3.6 — minimum peak/min ratio across the 6-interval motion
    /// profile to confirm a swing. A real swing has a sharp burst
    /// (ratio 5–20×); walking has a flat profile (ratio ~1.5×). The
    /// algorithm also requires the peak interval to fall within the
    /// swing window (intervals 3–5).
    /// V3.7 production default 8.0 — strict enough to reject most
    /// false positives. Lower to 4–5 if real swings get rejected.
    var motionThreshold: Double = 8.0

    /// How many seconds before the impact to grab Frame A. Kept as
    /// a setting for backwards compat / future tuning, but V3.6's
    /// algorithm uses a fixed 7-frame window; this value is unused.
    var motionBeforeOffsetSeconds: Double = 1.5

    /// Effective multiplier the detector should use right now —
    /// override if the user dialed it, otherwise the preset's default.
    var effectiveMultiplier: Double {
        detectionMultiplierOverride ?? preset.detectionMultiplier
    }

    init(preImpactSeconds: Double = 2.5,
         postImpactSeconds: Double = 2.5,
         preset: DetectionPreset = .recommended,
         detectionMultiplierOverride: Double? = nil,
         minimumSpacingSeconds: Double = 6.0,
         motionValidationEnabled: Bool = true,
         motionThreshold: Double = 8.0,
         motionBeforeOffsetSeconds: Double = 1.5) {
        self.preImpactSeconds = preImpactSeconds
        self.postImpactSeconds = postImpactSeconds
        self.preset = preset
        self.detectionMultiplierOverride = detectionMultiplierOverride
        self.minimumSpacingSeconds = minimumSpacingSeconds
        self.motionValidationEnabled = motionValidationEnabled
        self.motionThreshold = motionThreshold
        self.motionBeforeOffsetSeconds = motionBeforeOffsetSeconds
    }

    /// Forgiving decoder. Missing keys fall back to defaults, AND old
    /// preset raw values from previous V2 builds get mapped to V2.2:
    ///   "sensitive"    → catchMore
    ///   "balanced"     → catchMore
    ///   "conservative" → recommended
    /// V3 dropped fields (sensitivityThreshold, etc.) are silently
    /// ignored by Codable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.preImpactSeconds      = (try? c.decode(Double.self, forKey: .preImpactSeconds))      ?? 2.5
        self.postImpactSeconds     = (try? c.decode(Double.self, forKey: .postImpactSeconds))     ?? 2.5
        self.minimumSpacingSeconds = (try? c.decode(Double.self, forKey: .minimumSpacingSeconds)) ?? 6.0
        self.detectionMultiplierOverride = try? c.decode(Double.self, forKey: .detectionMultiplierOverride)
        self.motionValidationEnabled    = (try? c.decode(Bool.self,   forKey: .motionValidationEnabled))    ?? true
        self.motionThreshold            = (try? c.decode(Double.self, forKey: .motionThreshold))            ?? 8.0
        self.motionBeforeOffsetSeconds  = (try? c.decode(Double.self, forKey: .motionBeforeOffsetSeconds))  ?? 1.5
        // V3.5 → V3.6 migration: old motionThreshold values were
        // percentages (0–50). The new field is a ratio (1–10). If a
        // persisted value falls outside the new range, snap to default.
        if self.motionThreshold > 10.0 || self.motionThreshold < 1.0 {
            self.motionThreshold = 8.0
        }

        if let p = try? c.decode(DetectionPreset.self, forKey: .preset) {
            self.preset = p
        } else if let raw = try? c.decode(String.self, forKey: .preset) {
            switch raw {
            case "sensitive", "balanced":
                self.preset = .catchMore
            case "conservative":
                self.preset = .recommended
            default:
                self.preset = .recommended
            }
        } else {
            self.preset = .recommended
        }
    }

    static let `default` = DetectionSettings()

    // Reasonable bounds for sliders/steppers in the UI.
    static let preImpactRange:  ClosedRange<Double> = 0.5...10.0
    static let postImpactRange: ClosedRange<Double> = 0.5...10.0
    static let minSpacingRange: ClosedRange<Double> = 0.5...30.0
    static let multiplierRange:      ClosedRange<Double> = 1.0...10.0
    static let motionThresholdRange: ClosedRange<Double> = 1.0...20.0
}
