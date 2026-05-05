// DetectionConstants.swift
// V4 cleanup — single home for every magic number used by the swing
// detection pipeline. User-tunable settings (preset multiplier override,
// min-spacing, clip padding, motion-validation toggle) still live in
// DetectionSettings; this file holds the algorithmic constants that
// aren't user-facing and rarely change.
//
// The future "mode system" (range vs single-swing detection) will be
// implemented by introducing additional `DetectionConstants` instances
// (or a static `.rangeMode` / `.singleSwingMode` factory) and threading
// the chosen instance through the pipeline. That refactor is out of
// scope for this cleanup pass; the goal here is just consolidation so
// the next change is a one-line swap, not a hunt across files.

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
}
