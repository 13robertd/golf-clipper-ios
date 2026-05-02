// DetectionSettings.swift
// User-tunable settings for how we detect golf-swing impacts and cut clips.
// These are persisted to JSON so changes survive app launches.
//
// V2.2 — preset cleanup for V1 ship:
//  - Dropped `Sensitive` (was unused in real testing).
//  - Renamed `Balanced`     → `Catch More`   (same thresholds).
//  - Renamed `Conservative` → `Recommended`  (stricter thresholds).
//  - Default preset is `Recommended`.
//  - `minimumSpacingSeconds` default stays at 6.0.
//
// Backward-compat note: the forgiving decoder maps old persisted preset
// values to the new ones:
//    "sensitive"    → catchMore
//    "balanced"     → catchMore
//    "conservative" → recommended
//
// Pre/post-impact clip lengths are unchanged.

import Foundation

/// Detection sensitivity preset. Each preset bundles a set of thresholds
/// the AudioImpactDetector applies when classifying audio events.
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
            return "Finds more possible swings, but may include extra clips."
        case .recommended:
            return "Fewer false clips. Best for most videos."
        }
    }

    /// Hard floor on raw peak amplitude (0..1). Anything quieter is ignored.
    var minPeakAmplitude: Double {
        switch self {
        case .catchMore:   return 0.30
        case .recommended: return 0.45
        }
    }

    /// Required peak-to-noise ratio (peak / local noise floor).
    /// Real ball strikes are typically 6×–20× above ambient.
    var minPNR: Double {
        switch self {
        case .catchMore:   return 4.0
        case .recommended: return 7.0
        }
    }

    /// Minimum "attack" — how much louder the peak window is than the
    /// previous ~115 ms. Sharp ball strikes jump abruptly; whooshes ramp.
    var minSharpness: Double {
        switch self {
        case .catchMore:   return 0.15
        case .recommended: return 0.30
        }
    }

    /// Minimum composite confidence score (0..1) to accept.
    var minConfidence: Double {
        switch self {
        case .catchMore:   return 0.55
        case .recommended: return 0.76
        }
    }
}

struct DetectionSettings: Codable, Equatable {
    /// Seconds BEFORE the detected impact to keep in the clip.
    var preImpactSeconds: Double = 2.5

    /// Seconds AFTER the detected impact to keep in the clip.
    var postImpactSeconds: Double = 2.5

    /// Detection sensitivity preset (see `DetectionPreset`).
    /// Default is Recommended for V1: prioritize clean ball-contact clips
    /// over recall. Missed swings can still be saved with Manual Clip.
    var preset: DetectionPreset = .recommended

    /// Minimum spacing between two accepted impacts (seconds).
    /// Default 6.0: typical range cadence is ≥ 8s, so 6s safely separates
    /// real swings without merging them.
    var minimumSpacingSeconds: Double = 6.0

    init(preImpactSeconds: Double = 2.5,
         postImpactSeconds: Double = 2.5,
         preset: DetectionPreset = .recommended,
         minimumSpacingSeconds: Double = 6.0) {
        self.preImpactSeconds = preImpactSeconds
        self.postImpactSeconds = postImpactSeconds
        self.preset = preset
        self.minimumSpacingSeconds = minimumSpacingSeconds
    }

    /// Forgiving decoder. Missing keys fall back to defaults, AND old
    /// preset raw values from previous V2 builds get mapped to V2.2:
    ///   "sensitive"    → catchMore
    ///   "balanced"     → catchMore
    ///   "conservative" → recommended
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.preImpactSeconds      = (try? c.decode(Double.self, forKey: .preImpactSeconds))      ?? 2.5
        self.postImpactSeconds     = (try? c.decode(Double.self, forKey: .postImpactSeconds))     ?? 2.5
        self.minimumSpacingSeconds = (try? c.decode(Double.self, forKey: .minimumSpacingSeconds)) ?? 6.0

        // Preset: try the current enum first, then map any legacy string.
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
}
