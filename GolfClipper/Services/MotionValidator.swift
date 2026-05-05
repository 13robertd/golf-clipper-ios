// MotionValidator.swift
//
// V3.6/3.7 — temporal motion-profile validator.
//
// V3.5 compared one frame 1.5 s before impact to the impact frame and
// thresholded on % pixels changed. That conflated a swing with general
// movement: walking between shots, waggling the club, or starting the
// backswing all moved enough pixels to pass.
//
// V3.6 instead measures the SPEED of motion. A real golf swing is the
// fastest motion in the video — an explosive ~0.5 s burst surrounded by
// stillness. Walking is steady. Setup is steady. So we sample a 3-second
// window around the impact (T-2 .. T+1, 7 frames), compute pairwise
// pixel-diff scores between consecutive frames (6 scores), and look for
// a sharp PEAK in the middle of the window:
//
//   1: T-2.0 → T-1.5    (still at address — should be low)
//   2: T-1.5 → T-1.0    (still at address — should be low)
//   3: T-1.0 → T-0.5    (backswing starts — rising)
//   4: T-0.5 → T        (downswing through impact — PEAK)
//   5: T    → T+0.5     (follow-through — high)
//   6: T+0.5 → T+1.0    (decelerating — dropping)
//
// CONFIRMED criteria:
//   • peak / min ratio  >=  threshold (default 8×)   — there's a spike
//   • peak interval is 3, 4, or 5                    — spike is near impact
//
// REJECTED reasons:
//   • uniform motion (low ratio)        → walking, waggling, etc.
//   • peak in interval 1 or 2           → walking into position
//   • peak in interval 6                → audio likely offset from swing
//
// V3.7 — start/end clamping. When a candidate's window extends past the
// start or end of the video (e.g. an impact at 1.88 s wants Frame A at
// T-2.0 = -0.12 s), we clamp the offending timestamps into [0, duration]
// instead of bailing. The spike-ratio check then runs on whatever
// intervals are computable. We never default to CONFIRMED or REJECTED;
// the verdict is always derived from the profile that survives clamping.

import Foundation
import AVFoundation
import CoreGraphics

/// One per-candidate verdict, surfaced to the Settings/Debug screen.
struct MotionValidation: Codable, Hashable, Identifiable {
    var id: Double { time }
    let time: Double
    /// V3.6 — six inter-frame motion scores at 0.5 s intervals,
    /// covering [T-2.0, T+1.0]. Empty when extraction failed and
    /// the candidate was defaulted to CONFIRMED.
    let motionProfile: [Double]
    /// 1-based index of the interval with the highest score (1…6).
    /// 0 = invalid (extraction failed).
    let peakIntervalIndex: Int
    /// max(profile) / max(min(profile), epsilon).
    let peakRatio: Double
    let confirmed: Bool
    /// Short human-readable reason on rejection (or fallback note).
    let reason: String?

    /// Back-compat — V3.5 callers used `motionScore`. Returns the
    /// peak score from the profile, or 0 when the profile is empty.
    var motionScore: Double {
        motionProfile.max() ?? 0
    }
}

struct MotionValidationResult {
    /// Timestamps that survived validation.
    let validatedTimestamps: [Double]
    /// Per-candidate verdicts for the debug screen.
    let allValidations: [MotionValidation]
    /// V3.5 leftover — V3.6 always sets this to false because the
    /// new ratio-based logic naturally rejects camera-pan motion
    /// (uniform profile, low ratio). Kept on the struct so the
    /// AppState/UI plumbing doesn't have to change.
    let cameraMovingDetected: Bool
    let totalElapsedSeconds: Double
}

final class MotionValidator {

    /// Validate audio candidates against video motion. `progress(done,
    /// total)` fires before each candidate so the UI can show
    /// "Validating swing N of M…". `videoDuration` is used to clamp
    /// frame timestamps that fall outside [0, duration].
    ///
    /// **Profile-length assumption.** Each candidate is scored on a
    /// 6-element motion profile derived from 7 frame-grabs at fixed
    /// offsets `DetectionConstants.motionFrameOffsetsSeconds` around
    /// the audio impact. The shape classifier and zero-prefix gate
    /// rely on positional indices (first / peak / last) within this
    /// 6-element layout. If frame extraction fails on individual
    /// frames the profile is shorter than 6, but `intervalNumbers`
    /// preserves the original 1-based interval index so windows-3-4-5
    /// detection still works.
    ///
    /// **Profile units.** Each entry is the percentage (0–100) of
    /// downsampled pixels (160×120 = 19,200) whose grayscale value
    /// changed by more than `motionPixelChangeThreshold` between the
    /// two frames bracketing that interval. So 5.0 = "5% of pixels
    /// changed meaningfully" — modest motion. 25.0 = strong motion.
    ///
    // TODO: bug — silent motion-extraction failures. Multiple videos
    // produce all-zero motion profiles for valid mid-video timestamps
    // (70.58s in IMG_2253, 205.86s/217.82s in IMG_2252). The motion
    // extractor (`extractFrames`/`extractGrayBytes`) returns zeros
    // without surfacing a reason. The downstream "Almost no motion in
    // window" rejection masks the real failure. Investigate frame
    // extraction errors separately.
    //
    // TODO: bug — end-of-video motion profile artifact. Profiles like
    // [12.32, 14.90, 18.03, 14.14, 0.00, 0.00] (126.06s in IMG_2253)
    // emit trailing zeros because the video ends mid-window. The shape
    // classifier currently confirms on partial profiles; boundary
    // handling at end-of-video is unclear. Decide whether to clamp the
    // analysis window earlier or treat trailing-zero profiles as
    // suspect.
    func validate(videoURL: URL,
                  videoDuration: Double,
                  candidates: [Double],
                  threshold: Double,
                  progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> MotionValidationResult {

        let started = Date()
        guard !candidates.isEmpty else {
            return MotionValidationResult(
                validatedTimestamps: [],
                allValidations: [],
                cameraMovingDetected: false,
                totalElapsedSeconds: 0
            )
        }

        let asset = AVURLAsset(url: videoURL)
        let total = candidates.count
        var validations: [MotionValidation] = []
        validations.reserveCapacity(total)

        print("[NiceShot] Motion validation: \(total) candidates, ratio threshold \(String(format: "%.1f", threshold))×")

        for (i, time) in candidates.enumerated() {
            progress(i, total)
            let v = await validateCandidate(asset: asset,
                                            impactTime: time,
                                            videoDuration: videoDuration,
                                            threshold: threshold)
            logValidation(v)
            validations.append(v)
        }
        progress(total, total)

        let confirmedTimes = validations.filter { $0.confirmed }.map { $0.time }
        let elapsed = Date().timeIntervalSince(started)
        print("[NiceShot] Audio candidates: \(total)")
        print("[NiceShot] Motion confirmed: \(confirmedTimes.count)")
        print("[NiceShot] Motion rejected: \(total - confirmedTimes.count)")
        print(String(format: "[NiceShot] Validation time: %.2f seconds", elapsed))

        return MotionValidationResult(
            validatedTimestamps: confirmedTimes,
            allValidations: validations,
            cameraMovingDetected: false,
            totalElapsedSeconds: elapsed
        )
    }

    // MARK: - Per-candidate validation

    private func validateCandidate(asset: AVURLAsset,
                                   impactTime: Double,
                                   videoDuration: Double,
                                   threshold: Double) async -> MotionValidation {
        // V3.7 — clamp frame timestamps into the video's bounds. If
        // the impact is too close to the start, the early offsets clamp
        // to 0; if it's too close to the end, the late offsets clamp
        // to `videoDuration`. We extract whichever 7 timestamps result
        // and run the spike check on whatever intervals are available.
        let upperBound = max(0, videoDuration)
        let times = DetectionConstants.motionFrameOffsetsSeconds.map { offset -> Double in
            min(max(impactTime + offset, 0.0), upperBound)
        }

        let frames = await extractFrames(asset: asset, at: times)

        // Compute motion scores only for intervals where BOTH endpoints
        // were extracted successfully. After clamping, all 7 timestamps
        // are valid so this should normally produce 6 scores; the
        // nil-check below is defensive for decoder errors.
        var profile: [Double] = []
        var intervalNumbers: [Int] = []   // 1-based, 1…6
        profile.reserveCapacity(6)
        intervalNumbers.reserveCapacity(6)
        for i in 0..<(frames.count - 1) {
            guard let a = frames[i], let b = frames[i + 1] else { continue }
            profile.append(computePixelDiffScore(a: a, b: b))
            intervalNumbers.append(i + 1)
        }

        // If absolutely no intervals computed (every frame extraction
        // failed for some non-time reason like a decoder error), the
        // profile is empty. Return REJECTED — we promised never to
        // default to CONFIRMED, and there's nothing here to validate.
        guard !profile.isEmpty else {
            return MotionValidation(
                time: impactTime,
                motionProfile: [],
                peakIntervalIndex: 0,
                peakRatio: 0,
                confirmed: false,
                reason: "No frames could be extracted"
            )
        }

        let maxScore = profile.max() ?? 0

        // Peak interval is the original interval number (1–6) — not
        // the index within `profile`, which may have skipped some.
        let peakIdxInProfile = profile.firstIndex(of: maxScore) ?? 0
        let peakInterval = intervalNumbers[peakIdxInProfile]

        // Keep peak/median ratio for backward-compat logging only.
        // V3.13 doesn't use it for the verdict — see shape test below.
        let median = Self.median(of: profile)
        let denominator = max(median, DetectionConstants.motionMedianScoreFloor)
        let ratio = maxScore / denominator

        // === V3.13 — shape-based classification ====================
        //
        // Replaces V3.9's peak/median ratio test, which rejected real
        // swings whose pre-impact intervals had non-zero "windup" motion
        // (golfer addressing the ball, taking the club back). The
        // windup raised the median and compressed the peak/median ratio
        // below threshold. The shape test asks "does this look like a
        // swing?" instead of "is the peak much louder than the rest?"
        //
        // Pre-checks (preserved from V3.9):
        //   • All-zero / near-zero profile → REJECT (motion extraction
        //     failed or pure tripod noise)
        //   • Leading zeros (first N intervals < epsilon) → REJECT
        //     (impact at video start; no pre-impact data)
        //
        // Shape test (4 criteria; ≥3 must pass to CONFIRM):
        //   1. Low pre-motion baseline:   profile[0] < 0.25 × max
        //   2. Near-monotonic ramp:       ≤1 dip from index 0 to peak
        //   3. Peak in swing window:      interval ∈ {3,4,5,6} (1-based)
        //   4. Post-peak decay or sustain: profile[last] < profile[peak]
        //                                  (vacuous if peak is last)

        // Pre-check: all-zero / near-zero → REJECT.
        let hasRealMotion = maxScore >= DetectionConstants.motionMinPeakScore
        if !hasRealMotion {
            return MotionValidation(
                time: impactTime,
                motionProfile: profile,
                peakIntervalIndex: peakInterval,
                peakRatio: ratio,
                confirmed: false,
                reason: "Almost no motion in window — likely camera-stationary noise"
            )
        }

        // Pre-check: leading-zero prefix → REJECT (clamped frames at
        // video start).
        let leadingZeros = profile.prefix(DetectionConstants.motionZeroPrefixCount).filter { $0 < DetectionConstants.motionZeroPrefixEpsilon }.count
        if leadingZeros >= DetectionConstants.motionZeroPrefixCount {
            return MotionValidation(
                time: impactTime,
                motionProfile: profile,
                peakIntervalIndex: peakInterval,
                peakRatio: ratio,
                confirmed: false,
                reason: "Impact at video start — no pre-impact frames to validate against"
            )
        }

        // 4-criterion shape test (V3.13). ≥3-of-4 must pass to CONFIRM.
        // Each criterion is a separate predicate so per-criterion logging
        // can be added later without surgery on the orchestrator.
        var failures: [String] = []
        if !Self.hasLowPreMotionBaseline(profile) {
            failures.append("pre-motion too high")
        }
        let dips = Self.rampDipCount(profile, peakIndex: peakIdxInProfile)
        if !Self.hasNearMonotonicRampToPeak(profile, peakIndex: peakIdxInProfile) {
            failures.append("non-monotonic ramp (\(dips) dips)")
        }
        if !Self.peakInsideSwingWindow(peakInterval: peakInterval) {
            failures.append("peak at interval \(peakInterval) outside swing window")
        }
        if !Self.hasPostPeakDecay(profile, peakIndex: peakIdxInProfile) {
            failures.append("post-peak motion exceeds peak")
        }

        let passes = 4 - failures.count
        let confirmed = passes >= DetectionConstants.motionMinShapeCriteriaPassed
        let reason = confirmed ? nil : "shape: " + failures.joined(separator: ", ")

        return MotionValidation(
            time: impactTime,
            motionProfile: profile,
            peakIntervalIndex: peakInterval,
            peakRatio: ratio,
            confirmed: confirmed,
            reason: reason
        )
    }

    // MARK: - Frame extraction

    /// Extract all frames in parallel within one candidate. Sequential
    /// per-candidate (the caller's loop) keeps memory bounded; parallel
    /// per-frame keeps wall-clock time low.
    private func extractFrames(asset: AVURLAsset, at times: [Double]) async -> [[UInt8]?] {
        await withTaskGroup(of: (Int, [UInt8]?).self) { group in
            for (idx, time) in times.enumerated() {
                group.addTask {
                    let bytes = await self.extractGrayBytes(asset: asset, at: time)
                    return (idx, bytes)
                }
            }
            var results: [[UInt8]?] = Array(repeating: nil, count: times.count)
            for await (idx, bytes) in group {
                results[idx] = bytes
            }
            return results
        }
    }

    private func extractGrayBytes(asset: AVURLAsset, at time: Double) async -> [UInt8]? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: DetectionConstants.motionFrameWidth,
                                       height: DetectionConstants.motionFrameHeight)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter  = CMTime(value: 1, timescale: 10)

        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: cmTime)
            return grayBytes(from: cgImage)
        } catch {
            return nil
        }
    }

    /// Render a CGImage into a fixed-size grayscale UInt8 buffer.
    private func grayBytes(from image: CGImage) -> [UInt8]? {
        let w = DetectionConstants.motionFrameWidth
        let h = DetectionConstants.motionFrameHeight
        var bytes = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        guard let context = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    // MARK: - Pixel diff

    /// Returns 0–100. Plain Swift loop over 19,200 pixels — well within
    /// "free" territory; vDSP would shave maybe 1 ms per pair.
    private func computePixelDiffScore(a: [UInt8], b: [UInt8]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var changed = 0
        let thresh = DetectionConstants.motionPixelChangeThreshold
        for i in 0..<count {
            let diff = abs(Int(a[i]) - Int(b[i]))
            if diff > thresh { changed += 1 }
        }
        return Double(changed) / Double(count) * 100.0
    }

    // MARK: - Logging

    private func logValidation(_ v: MotionValidation) {
        let verdict = v.confirmed ? "CONFIRMED" : "REJECTED"
        if v.motionProfile.isEmpty {
            print(String(format: "[NiceShot] Candidate at %.2fs: extraction failed → %@ (%@)",
                         v.time,
                         verdict,
                         v.reason ?? "defaulted"))
            return
        }
        let profileStr = "[" + v.motionProfile
            .map { String(format: "%.2f", $0) }
            .joined(separator: ", ") + "]"
        let reasonSuffix = v.reason.map { " (\($0))" } ?? ""
        print(String(format:
            "[NiceShot] Candidate at %.2fs: motion profile = %@ peak at interval %d (ratio %.1f×) → %@%@",
            v.time,
            profileStr,
            v.peakIntervalIndex,
            v.peakRatio,
            verdict,
            reasonSuffix
        ))
    }

    // MARK: - Stats helpers

    /// Median of a non-empty array of doubles. For even counts, returns
    /// the average of the two middle values. Used by V3.9 peak/median
    /// ratio in place of the unstable peak/min ratio.
    // MARK: - Shape-test predicates (V3.13)

    /// Criterion 1: profile[0] is below half of peak motion. Real
    /// swings start from a relatively still address position; while
    /// some pre-motion is allowed (windup, walking-into-position in
    /// busy range footage), the first interval shouldn't be louder
    /// than half the peak.
    private static func hasLowPreMotionBaseline(_ profile: [Double]) -> Bool {
        guard let first = profile.first, let max = profile.max() else { return false }
        return first < DetectionConstants.motionMaxPreMotionFractionOfPeak * max
    }

    /// Criterion 2: from index 0 to the peak, allow at most
    /// `motionMaxRampDips` windows where the value drops below the
    /// previous one. Pure noise won't have this near-monotonic shape;
    /// a swing will.
    private static func hasNearMonotonicRampToPeak(_ profile: [Double], peakIndex: Int) -> Bool {
        rampDipCount(profile, peakIndex: peakIndex) <= DetectionConstants.motionMaxRampDips
    }

    /// Helper for criterion 2 — surfaced separately so the failure
    /// reason string can quote the exact dip count.
    private static func rampDipCount(_ profile: [Double], peakIndex: Int) -> Int {
        var dips = 0
        if peakIndex >= 1 {
            for i in 1...peakIndex where profile[i] < profile[i - 1] {
                dips += 1
            }
        }
        return dips
    }

    /// Criterion 3: 1-based peak interval is inside the configured
    /// swing window. Peak should occur at or just before the audio
    /// impact, not at the very start of the analysis window.
    private static func peakInsideSwingWindow(peakInterval: Int) -> Bool {
        DetectionConstants.motionAcceptablePeakIntervals.contains(peakInterval)
    }

    /// Criterion 4: if the peak isn't in the final interval, motion
    /// has decayed by the end of the window. Vacuous when the peak
    /// IS the last interval (follow-through-dominant profiles).
    private static func hasPostPeakDecay(_ profile: [Double], peakIndex: Int) -> Bool {
        let isLastInterval = peakIndex == profile.count - 1
        if isLastInterval { return true }
        guard let last = profile.last else { return true }
        return last < profile[peakIndex]
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return sorted[n / 2]
        }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}
