// DetectionConstants.swift
// V4 cleanup — single home for every magic number used by the swing
// detection pipeline. User-tunable settings (preset multiplier override,
// min-spacing, clip padding, motion-validation toggle) still live in
// DetectionSettings; this file holds the algorithmic constants that
// aren't user-facing and rarely change.
//
// V4.1 — mode system. Two named tuning bundles live alongside the
// static algorithm constants: `singleSwingMode` and `rangeSessionMode`.
// Modes affect only min-spacing and the loudest-peak fallback gate —
// audio multiplier, motion criteria, and dominance threshold are shared.
// The pipeline auto-selects a mode by video duration and persists the
// choice on each ImportedVideo; the user can override via the UI chip.

import Foundation

enum DetectionConstants {

    // MARK: - Audio detection (AudioImpactDetector)

    /// Audio analysis window length in seconds. Each window's RMS is
    /// computed once and feeds the energy-ratio calculation. 20ms is a
    /// good trade between time resolution (we want sub-100ms accuracy
    /// on impact location) and CPU cost (~50 windows/sec instead of
    /// ~44 100 raw samples).
    static let audioWindowSeconds: Double = 0.020

    /// How many preceding windows feed the rolling-mean denominator
    /// of the energy ratio. With audioWindowSeconds = 20ms, 10 windows
    /// = 200ms of history. Long enough to smooth out background noise
    /// trends but short enough that a sudden impact still produces a
    /// large peak/(prev-mean) ratio.
    static let audioPrevWindowsForRatio: Int = 10

    /// Floor on the rolling-mean denominator to prevent divide-by-near-
    /// zero ratios in dead-silent stretches of audio. Matches the V3
    /// detector's pre-cleanup `denominatorFloor` value (0.01).
    static let audioRatioDenominatorFloor: Double = 0.01

    /// Two raw peaks closer together than this collapse to one (the
    /// louder one wins). Captures the cluster of windows above
    /// threshold around a single impact (initial click + ground
    /// contact + echo) into a single event.
    static let audioDedupWindowSeconds: Double = 0.5

    // MARK: - Audio transient classifier (V3.11)

    /// Attack-rise threshold: a window is part of the "rising edge"
    /// of a peak if its RMS is at least this fraction of the peak RMS.
    /// Counted toward the attack window count.
    static let transientRisingFractionOfPeak: Double = 0.25

    /// Sustain threshold: a post-peak window is "still elevated" if
    /// its RMS is at least this fraction of the peak. Counted toward
    /// the duration window count.
    static let transientElevatedFractionOfPeak: Double = 0.50

    /// Maximum allowed attack time (ms) for a candidate to be classified
    /// IMPACT-LIKE. Sharp impacts attack in 0–20ms; speech typically
    /// 50ms+ gradual.
    static let transientMaxAttackMs: Int = 30

    /// Maximum allowed elevated duration (ms) for IMPACT-LIKE. Sharp
    /// impacts decay in 20–100ms; speech sustains 200ms+.
    static let transientMaxDurationMs: Int = 150

    // MARK: - Motion shape classifier (V3.13)

    /// Frame-grab time offsets (seconds) relative to the audio impact.
    /// 7 frames → 6 motion intervals between consecutive frames.
    /// Symmetric around the impact (offset 0) so we can see both the
    /// build-up (negative offsets) and the follow-through (positive).
    static let motionFrameOffsetsSeconds: [Double] = [-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0]

    /// Downsampled frame size for motion analysis. 160×120 = 19,200
    /// pixels — small enough to diff per-pixel cheaply, large enough
    /// to capture body-scale motion.
    static let motionFrameWidth: Int = 160
    static let motionFrameHeight: Int = 120

    /// Per-pixel grayscale change threshold (0–255). A pixel counts
    /// as "changed" between frames if its absolute byte delta exceeds
    /// this. 20 of 255 ≈ 7.8% — well above JPEG quantization noise
    /// (~3–5) and below the actual delta of moving body pixels.
    static let motionPixelChangeThreshold: Int = 20

    /// 1-based interval indices acceptable as the peak position. Real
    /// golf swings tend to peak AT or just AFTER impact (intervals
    /// 4–5) because follow-through and ball flight produce more
    /// visible motion than the impact moment itself. Interval 6
    /// (peak at end) is also allowed for short follow-through windows.
    static let motionAcceptablePeakIntervals: Set<Int> = [3, 4, 5, 6]

    /// Pre-motion baseline as a fraction of peak. Profile[0] must be
    /// below `peak × this` to satisfy criterion 1 of the shape test.
    /// 0.5 was tuned for multi-swing range videos where the previous
    /// swing's follow-through keeps continuous activity high; in
    /// quieter videos the value almost never matters because pre-
    /// motion is < 5% of peak.
    static let motionMaxPreMotionFractionOfPeak: Double = 0.5

    /// Maximum number of "dips" (windows where profile[i] < profile[i-1])
    /// allowed in the ramp from start to peak. Real swings have a
    /// near-monotonic build-up; ≤1 dip allows for momentary
    /// deceleration mid-windup.
    static let motionMaxRampDips: Int = 1

    /// Minimum criteria (out of 4) a profile must satisfy to be CONFIRMED.
    static let motionMinShapeCriteriaPassed: Int = 3

    /// Floor on the median denominator for the legacy peak/median ratio.
    /// V3.13 doesn't use the ratio for verdicts (replaced by shape test)
    /// but it's still computed for diagnostic logging and the Settings
    /// debug screen.
    static let motionMedianScoreFloor: Double = 0.01

    /// Absolute floor on the PEAK score (% of pixels changed). If the
    /// busiest interval in the window has fewer pixels changed than
    /// this, there's no real motion to validate — bypass the shape
    /// test entirely and reject. Filters out tripod-noise-only profiles.
    static let motionMinPeakScore: Double = 1.0

    /// Zero-prefix detection: if the first N intervals are below
    /// `zeroPrefixEpsilon`, frame extraction was clamped (impact
    /// happened at t < 0.5s in the video) and we have no pre-impact
    /// data. Reject regardless of post-impact motion shape.
    static let motionZeroPrefixCount: Int = 3
    static let motionZeroPrefixEpsilon: Double = 0.05

    // MARK: - Pipeline orchestration (AppState)

    /// V3.10 — A single audio peak is "dominant" (auto-confirmed,
    /// bypasses motion validation) if its energyRatio is at least this
    /// multiple of the next-strongest pre-filter survivor. Real swings
    /// tend to dominate the audio signal of a video; when one peak is
    /// meaningfully louder than every other event, ignoring that signal
    /// because motion happens to be uniform throws away the strongest
    /// cue we have.
    static let dominanceMultiplier: Double = 2.0

    /// V3.12 — Candidates at t below this threshold are pre-rejected
    /// because the motion validator can't get pre-impact frames (frame
    /// extraction would clamp them all to t=0). Done here in addition
    /// to the validator's zero-prefix check so doomed candidates don't
    /// inflate the dominance comparison's denominator.
    static let zeroPrefixPredictionThresholdSeconds: Double = 0.5

    /// V3.8 — Videos shorter than this get the short-video accommodations
    /// (loosened spacing, skipped motion validation, loudest-peak
    /// fallback). 15s is short enough to confidently say "user filmed
    /// one swing on purpose" and long enough to fit a full pre/post-
    /// impact window.
    static let shortVideoThresholdSeconds: Double = 15.0

    /// V3.8 — For videos under this duration, force min-spacing down to
    /// `shortVideoMinSpacingSeconds` so a brief recording with two real
    /// peaks (mishit + reset whack) doesn't lose the second one to the
    /// default 6.0s cooldown.
    static let shortVideoSpacingThresholdSeconds: Double = 30.0
    static let shortVideoMinSpacingSeconds: Double = 2.0

    // MARK: - Logging

    /// Master switch for the verbose diagnostic logs added during
    /// detection iteration (top-30 raw peaks, threshold-rejected list,
    /// dedup/spacing drop details, threshold derivation breakdown,
    /// per-candidate transient verdict, dominance comparison, pre-
    /// filter rejections). The PIPELINE SUMMARY, per-candidate motion
    /// verdict, and dominant auto-confirm lines are always on.
    ///
    /// Defaults to ON in DEBUG builds (we're still iterating on
    /// detection accuracy and want full visibility) and OFF in RELEASE
    /// (don't ship verbose logs to the App Store).
    static let verboseLogging: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Single gated-print helper. Use `@autoclosure` so the message
    /// string isn't constructed at all when verboseLogging is off —
    /// matters for logs with format strings inside hot loops.
    @inline(__always)
    static func verboseLog(_ message: @autoclosure () -> String) {
        if verboseLogging {
            print(message())
        }
    }

    // MARK: - V4.1 mode tuning

    /// Per-mode tuning bundle. Modes intentionally share the audio
    /// multiplier, motion-shape criteria, and dominance multiplier —
    /// only the two values below differ. Adding more knobs here is
    /// the supported extension point if future modes need to diverge
    /// further (e.g. a `quietShot` mode for chips/putts in V1.1).
    struct ModeValues {
        /// Min-spacing seconds applied during the audio "loudest wins"
        /// cooldown. Overrides DetectionSettings.minimumSpacingSeconds
        /// when the pipeline runs (the user-visible setting is left
        /// alone). The V3.8 short-video clamp still applies on top.
        let minSpacingSeconds: Double
        /// Dominance multiplier passed to findDominantAudioPeak. Kept
        /// per-mode (rather than always-constant) so a future mode
        /// can tune this without touching DetectionConstants's other
        /// static fields.
        let dominanceMultiplier: Double
        /// V3.8's loudest-peak fallback fires when the pipeline produces
        /// zero clips AND the video is "short" (<15s). For singleSwing
        /// mode we want that safety net regardless of duration — a
        /// 90s recording of one quiet swing should not silently produce
        /// no clips. For rangeSession we keep the short-only gate (a
        /// long range video with zero confirmed swings genuinely has
        /// no swings, not a missed loudest peak).
        let alwaysApplyLoudestFallback: Bool
        /// V4.2 — after the full pipeline runs, keep only the highest-
        /// confidence surviving candidate. The mode's name promises a
        /// single clip; min-spacing alone doesn't deliver that when
        /// three audio peaks are 2.5s apart and all pass motion. Ranking
        /// preference: auto-confirmed dominant peak first, then highest
        /// audio energy ratio among motion-confirmed survivors.
        let keepTopCandidateOnly: Bool
    }

    /// Tuning for a single deliberate swing (quiet environment, one shot).
    /// Audio threshold matches rangeSession — IMG_1958's swing comes in
    /// at 8.66× ratio against a 3.288× threshold, so the impact has a
    /// huge margin against the standard 5.0× multiplier. Lowering the
    /// multiplier would admit speculative extra candidates without
    /// helping on the known test case.
    static let singleSwingMode = ModeValues(
        minSpacingSeconds: 2.0,
        dominanceMultiplier: 2.0,
        alwaysApplyLoudestFallback: true,
        keepTopCandidateOnly: true
    )

    /// Tuning for a multi-swing range recording (noisy, multiple swings).
    /// Matches the V3.7 production values; this mode is what the pipeline
    /// has always done. Keeping these unchanged is what preserves the
    /// IMG_2253 (5 clips) / IMG_2252 (11 clips) baselines.
    static let rangeSessionMode = ModeValues(
        minSpacingSeconds: 6.0,
        dominanceMultiplier: 2.0,
        alwaysApplyLoudestFallback: false,
        keepTopCandidateOnly: false
    )

    /// Duration cutoff for auto-detect. Videos shorter than this default
    /// to singleSwing; longer ones default to rangeSession. The chip is
    /// the user's path to correct misclassifications in the 30–120s
    /// ambiguous zone where duration alone can't distinguish.
    static let modeAutoDetectDurationCutoffSeconds: Double = 30.0
}

/// V4.1 — Which tuning bundle a video uses. Persisted per-video in
/// ImportedVideo; user can override via the chip on ClipReviewView or
/// SourceVideoPreviewView. The auto-detect heuristic only runs on the
/// first processing pass — the choice is persisted so future heuristic
/// tweaks don't silently shift a video's behavior between launches.
enum DetectionMode: String, Codable, Hashable, CaseIterable {
    case singleSwing
    case rangeSession

    var values: DetectionConstants.ModeValues {
        switch self {
        case .singleSwing:  return DetectionConstants.singleSwingMode
        case .rangeSession: return DetectionConstants.rangeSessionMode
        }
    }

    var displayName: String {
        switch self {
        case .singleSwing:  return "Single swing"
        case .rangeSession: return "Range session"
        }
    }

    var summary: String {
        switch self {
        case .singleSwing:
            return "Lenient filtering for single-swing videos."
        case .rangeSession:
            return "Stricter filtering for multi-swing range videos."
        }
    }

    var symbolName: String {
        switch self {
        case .singleSwing:  return "figure.golf"
        case .rangeSession: return "square.grid.3x3.fill"
        }
    }

    /// The only other mode. Since V1 is exactly two modes, the chip's
    /// tap action and the "switch back" empty-state CTA both target
    /// `.opposite` — no separate "previous mode" needs to be tracked.
    var opposite: DetectionMode {
        switch self {
        case .singleSwing:  return .rangeSession
        case .rangeSession: return .singleSwing
        }
    }

    /// V4.1 — Cheap duration-based auto-detect. The three test videos
    /// classify cleanly: IMG_1958 (19.7s) → singleSwing; IMG_2253 (126s)
    /// and IMG_2252 (226s) → rangeSession. The 30–120s zone is known to
    /// misclassify single-swing videos with extra silence around them;
    /// the chip is the V1 fix for that case.
    static func autoDetect(forDuration duration: Double) -> DetectionMode {
        if duration < DetectionConstants.modeAutoDetectDurationCutoffSeconds {
            return .singleSwing
        }
        return .rangeSession
    }
}
