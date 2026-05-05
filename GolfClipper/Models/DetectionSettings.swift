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
    /// V3.9 — ratio is now peak/median (was peak/min). Median is more
    /// stable: a single outlier interval can't blow the ratio up.
    /// Real swings: 1.5–4× peak/median. Walking: ~1.0–1.2×.
    /// Production default 3.0× — picks up real swings with margin
    /// while rejecting walking/stationary noise. Lower to 2.0× if
    /// real swings get rejected; raise to 4.0× if false positives
    /// from background motion creep in.
    /// (Old V3.7 default was 8.0× peak/min — different scale; the
    /// decoder migration below resets persisted V3.7 values.)
    ///
    // TODO: vestigial — V3.13 motion validator uses shape criteria
    // (DetectionConstants.motionAcceptablePeakIntervals + the four
    // shape predicates) instead of a peak/median ratio threshold.
    // The Settings/Debug UI still exposes this slider, and the
    // peak/median ratio is still computed for diagnostic display, but
    // the value no longer influences confirmation. Address in a
    // follow-up: either restore ratio-based veto, or strip the slider
    // and persisted field.
    var motionThreshold: Double = 3.0

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
         motionThreshold: Double = 3.0) {
        self.preImpactSeconds = preImpactSeconds
        self.postImpactSeconds = postImpactSeconds
        self.preset = preset
        self.detectionMultiplierOverride = detectionMultiplierOverride
        self.minimumSpacingSeconds = minimumSpacingSeconds
        self.motionValidationEnabled = motionValidationEnabled
        self.motionThreshold = motionThreshold
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
        self.motionThreshold            = (try? c.decode(Double.self, forKey: .motionThreshold))            ?? 3.0
        // Note: motionBeforeOffsetSeconds (formerly stored at this point)
        // was removed in V4 cleanup as dead code — never read by any
        // pipeline stage. Existing JSON containing the field is silently
        // ignored by the forgiving decoder.
        // V3.5 → V3.6 migration: old values were percentages (0–50).
        // V3.7/V3.8 default was 8.0 (peak/min metric).
        // V3.9 default is 3.0 (peak/median metric — different scale).
        // Anything > 6.0 is a stale peak/min value; reset to V3.9 default.
        if self.motionThreshold > 6.0 || self.motionThreshold < 1.0 {
            self.motionThreshold = 3.0
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
    /// V3.9 — peak/median ratio range. Real swings: 1.5–4×.
    /// Slider tops out at 6× (anything higher rejects everything in practice).
    static let motionThresholdRange: ClosedRange<Double> = 1.0...6.0
}
