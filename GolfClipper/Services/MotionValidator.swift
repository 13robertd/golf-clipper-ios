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

    // Small fixed thumbnail size — motion detection doesn't need pixels.
    private static let frameWidth  = 160
    private static let frameHeight = 120
    /// Per-pixel grayscale change threshold (0–255).
    private static let pixelChangeThreshold: Int = 20

    /// Time offsets relative to impact for the 7-frame profile.
    private static let frameOffsets: [Double] = [-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0]
    /// 1-based interval indices acceptable as the peak position.
    private static let acceptablePeakIntervals: Set<Int> = [3, 4, 5]
    /// Floor on the min-score denominator. Without this, an interval
    /// with literally 0 % changed pixels would blow the ratio to ∞.
    private static let minScoreFloor: Double = 0.001
    /// Absolute floor on the PEAK score. If the busiest interval in
    /// the window has fewer than this many pixels changed, there's no
    /// real motion to validate — the spike ratio is just noise being
    /// amplified by the min-score floor. 1.0 % of 19,200 pixels = 192
    /// pixels, well above the JPEG/quantization noise of ~50 pixels
    /// but well below the typical 5–30 % peak of a real swing.
    private static let minPeakMotionScore: Double = 1.0

    /// Validate audio candidates against video motion. `progress(done,
    /// total)` fires before each candidate so the UI can show
    /// "Validating swing N of M…". `videoDuration` is used to clamp
    /// frame timestamps that fall outside [0, duration].
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
        let times = Self.frameOffsets.map { offset -> Double in
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
        let minScoreRaw = profile.min() ?? 0
        let minScore = max(minScoreRaw, Self.minScoreFloor)
        let ratio = maxScore / minScore

        // Peak interval is the original interval number (1–6) — not
        // the index within `profile`, which may have skipped some.
        let peakIdxInProfile = profile.firstIndex(of: maxScore) ?? 0
        let peakInterval = intervalNumbers[peakIdxInProfile]

        let inSwingWindow = Self.acceptablePeakIntervals.contains(peakInterval)
        let hasSpeedSpike = ratio >= threshold
        // Sanity check: even if the ratio looks high, the absolute
        // peak motion has to be meaningful. Without this, a stationary
        // tripod with 0 %-ish noise across all six intervals can have
        // a single interval at e.g. 0.04 %, and divide-by-floor blows
        // that into a "huge" ratio that confirms a non-existent swing.
        let hasRealMotion = maxScore >= Self.minPeakMotionScore
        let confirmed = inSwingWindow && hasSpeedSpike && hasRealMotion

        let reason: String?
        if confirmed {
            reason = nil
        } else if !hasRealMotion {
            reason = "Almost no motion in window — likely camera-stationary noise"
        } else if !hasSpeedSpike && !inSwingWindow {
            reason = "No speed spike, peak outside swing window"
        } else if !hasSpeedSpike {
            reason = "Uniform motion — likely walking"
        } else {
            // Spike exists but in interval 1, 2, or 6 — wrong place.
            if peakInterval <= 2 {
                reason = "Peak before swing window — likely walking into position"
            } else {
                reason = "Peak after swing window — audio may be offset"
            }
        }

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
        generator.maximumSize = CGSize(width: Self.frameWidth,
                                       height: Self.frameHeight)
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
        let w = Self.frameWidth
        let h = Self.frameHeight
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
        let thresh = Self.pixelChangeThreshold
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
}
