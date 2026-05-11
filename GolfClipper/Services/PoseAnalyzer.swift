// PoseAnalyzer.swift
//
// V4.3 — Phase 1 research spike. NOT a production feature.
// Iteration 3: P8 replaced with P10 (Finish Position). P10 is the
// "trophy pose" at the end of the swing — easier to detect than P8
// because it has a clean stillness signal (mirror of P1).
//
// Detects candidate frames for four P-positions per clip:
//   • P1  — Address (earliest pre-swing stillness in first 1.5s)
//   • P4  — Top of Backswing (90%-max wrist height with ascending-before /
//           descending-after directional context)
//   • P7  — Impact (caller-supplied within-clip timestamp from audio detect)
//   • P10 — Finish (earliest post-swing stillness in last 1.5s, or
//           shorter window for end-of-source clips)
//
// Output: four annotated JPEG stills written into the caller-supplied
// directory + structured [NiceShot] logs.
//
// Hard rule: production pipeline is untouched. This file is a leaf —
// reads a clip URL + impact timestamp + output directory, writes JPEGs.
//
// Assumptions (documented for the spike report):
//   • Right-handed golfer: lead = anatomical left side.
//   • Multi-person frames pick the observation with the largest bbox.
//   • Sample rate 10 Hz (100ms grid).
//   • Joint confidence floor 0.3 for "usable" lead-side joints.
//   • Vision uses normalized image coords (origin bottom-left, y up).

import Foundation
import AVFoundation
import Vision
import UIKit

// MARK: - Public types

struct PoseDetectionResult {
    let videoURL: URL
    let p1Frame: PoseFrameCandidate?
    let p4Frame: PoseFrameCandidate?
    let p7Frame: PoseFrameCandidate?
    let p10Frame: PoseFrameCandidate?
    let totalFramesAnalyzed: Int
    let analysisTimeSeconds: TimeInterval
    let outputDirectory: URL
    let savedStillURLs: [URL]
}

struct PoseFrameCandidate {
    let timestamp: TimeInterval
    /// Average confidence of the lead-wrist + lead-shoulder joints at
    /// the chosen frame. NOT a single Vision "frame confidence" — Vision
    /// doesn't expose one; this is the per-frame signal most relevant
    /// to the spike's go/no-go judgement.
    let confidence: Float
    let reasoning: String
}

// MARK: - Analyzer

final class PoseAnalyzer {

    // Tuning constants for the spike. NOT promoted to DetectionConstants —
    // research-pass thresholds should NOT mix into the production namespace.
    private let sampleHz: Double = 10.0
    private let p1StillnessThreshold: Double = 0.015
    private let p1StillnessWindowSamples: Int = 3            // 300ms at 10Hz
    private let p1WindowSecondsNormal: Double = 1.5
    private let p1WindowShortClipThreshold: Double = 4.0     // clips < 4s use proportional window
    private let p1WindowShortClipFraction: Double = 0.4
    private let p4HeightFractionOfMax: Double = 0.90
    private let p4DirectionalWindowSeconds: Double = 0.2
    private let p4SearchStartOffsetFromP1: Double = 0.5
    private let p4SearchEndOffsetFromP7: Double = 0.2
    // P10 (Finish) — mirror of P1 against the end of the clip.
    // V4.3 iter 3.1 — threshold bumped 0.020 → 0.050 based on observed
    // real-world minimum stddev values (0.057, 0.058, 0.080). 0.050 is
    // the prompt-specified value; further iteration on this number is
    // explicitly out of scope.
    private let p10StillnessThreshold: Double = 0.050
    private let p10StillnessWindowSamples: Int = 3            // 300ms at 10Hz
    private let p10SearchWindowSeconds: Double = 1.5
    private let p10BufferAfterP7: Double = 0.5
    private let p10MinSearchWindowSeconds: Double = 0.5       // below this: last-frame fallback
    private let p10MinPostImpactSeconds: Double = 0.3         // below this: nil (no p10.jpg)
    private let jointConfidenceFloor: Float = 0.3
    private let bboxConfidenceFloor: Float = 0.1

    // Lead side = anatomical left (right-handed golfer assumption).
    private let leadWristJoint: VNHumanBodyPoseObservation.JointName = .leftWrist
    private let leadShoulderJoint: VNHumanBodyPoseObservation.JointName = .leftShoulder
    private let leadHipJoint: VNHumanBodyPoseObservation.JointName = .leftHip

    // MARK: - Internal types

    private struct PoseSample {
        let timestamp: TimeInterval
        let joints: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
        let boundingBox: CGRect?
        let observationCount: Int

        var isUsable: Bool { !joints.isEmpty }
    }

    // MARK: - Public entry point (iteration 2 API)

    /// Run pose detection on a single exported clip and write four
    /// annotated stills into `outputDirectory`. Caller supplies the
    /// precise within-clip impact (typically `clip.impactTimestamp -
    /// clip.startTime`) so the heuristic guess from iteration 1 is gone.
    func analyzeSwing(in clipURL: URL,
                      impactTimeInClip: TimeInterval,
                      outputDirectory: URL) async throws -> PoseDetectionResult {
        let started = Date()
        let asset = AVURLAsset(url: clipURL)
        let durationCM = try await asset.load(.duration)
        let clipDuration = CMTimeGetSeconds(durationCM)

        // V4.3 iter 3 — sample the full clip duration so P10's last-1.5s
        // stillness search has frames to work with. P1/P4/P7 detectors
        // still only consume the [0, P7] subset of the samples array —
        // their outputs are unchanged from iter 2 (regression-checked
        // by review of detector code paths).
        let endSec = clipDuration

        print(String(format: "[NiceShot] PoseSpike: clip duration %.2fs, impact at %.2fs within clip",
                     clipDuration, impactTimeInClip))

        let samples = try await extractPoseSamples(asset: asset, from: 0.0, to: endSec)

        let usable = samples.filter { $0.isUsable }
        let usablePct = samples.isEmpty ? 0 : Int(Double(usable.count) / Double(samples.count) * 100)
        print("[NiceShot] PoseSpike: usable frames \(usable.count)/\(samples.count) (\(usablePct)%)")

        let multiPersonCount = samples.filter { $0.observationCount > 1 }.count
        if multiPersonCount > 0 {
            print("[NiceShot] PoseSpike: multi-person on \(multiPersonCount) frame(s) — largest bbox selected each time")
        }

        let p1 = detectP1(samples: samples, clipDuration: clipDuration)
        let p4 = detectP4(samples: samples,
                          p1Time: p1?.timestamp ?? 0,
                          p7Time: impactTimeInClip)
        let p7 = makeP7(samples: samples, time: impactTimeInClip)
        let p10 = detectP10(samples: samples,
                            p7Time: impactTimeInClip,
                            clipDuration: clipDuration)

        for (name, candidate) in [("P1", p1), ("P4", p4), ("P10", p10)] {
            if let c = candidate {
                print(String(format: "[NiceShot] PoseSpike: %@ candidate at %.2fs within clip (confidence %.2f, reasoning: %@)",
                             name, c.timestamp, c.confidence, c.reasoning))
            } else {
                print("[NiceShot] PoseSpike: \(name) candidate: NONE (no usable frames in window)")
            }
        }
        print(String(format: "[NiceShot] PoseSpike: P7 at %.2fs (impact center)", impactTimeInClip))

        // Caller controls the output directory (see SourceVideoPreviewView).
        // Make sure it exists; caller already creates it but defending against
        // accidental misuse.
        try? FileManager.default.createDirectory(at: outputDirectory,
                                                 withIntermediateDirectories: true)

        var savedURLs: [URL] = []
        let stillsToSave: [(label: String, candidate: PoseFrameCandidate?)] = [
            ("p1", p1), ("p4", p4), ("p7", p7), ("p10", p10)
        ]
        for entry in stillsToSave {
            guard let c = entry.candidate else { continue }
            let sample = closestSample(to: c.timestamp, in: samples)
            let url = outputDirectory.appendingPathComponent("\(entry.label).jpg")
            do {
                try await saveAnnotatedStill(
                    asset: asset,
                    time: c.timestamp,
                    label: stillLabel(for: entry.label, candidate: c),
                    sample: sample,
                    to: url
                )
                savedURLs.append(url)
            } catch {
                print("[NiceShot] PoseSpike: failed to save \(entry.label) still: \(error.localizedDescription)")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "[NiceShot] PoseSpike: clip analysis: %d frames in %.1fs",
                     samples.count, elapsed))

        return PoseDetectionResult(
            videoURL: clipURL,
            p1Frame: p1,
            p4Frame: p4,
            p7Frame: p7,
            p10Frame: p10,
            totalFramesAnalyzed: samples.count,
            analysisTimeSeconds: elapsed,
            outputDirectory: outputDirectory,
            savedStillURLs: savedURLs
        )
    }

    // MARK: - Frame extraction + Vision pass

    private func extractPoseSamples(asset: AVURLAsset,
                                    from startSec: TimeInterval,
                                    to endSec: TimeInterval) async throws -> [PoseSample] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        let interval = 1.0 / sampleHz
        var times: [TimeInterval] = []
        var t = startSec
        while t <= endSec {
            times.append(t)
            t += interval
        }

        var samples: [PoseSample] = []
        var multiPersonLogged = 0
        let maxMultiPersonLogs = 10

        for time in times {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: cmTime).image else {
                samples.append(PoseSample(timestamp: time, joints: [:], boundingBox: nil, observationCount: 0))
                continue
            }

            let observations = await runPoseRequest(on: cgImage)
            if observations.isEmpty {
                samples.append(PoseSample(timestamp: time, joints: [:], boundingBox: nil, observationCount: 0))
                continue
            }

            // TODO: bug — body detection nondeterminism across runs on same input.
            // Observed: same source video produced 50/51 vs 19/51 usable frames on two consecutive runs.
            // Likely cause: multi-person bbox selection flipping between people in the scene,
            // or Vision body detection model nondeterminism. Investigate after V1.
            let withBoxes = observations.map { ($0, boundingBox(for: $0)) }
            guard let selected = withBoxes.max(by: { ($0.1.width * $0.1.height) < ($1.1.width * $1.1.height) }) else {
                samples.append(PoseSample(timestamp: time, joints: [:], boundingBox: nil, observationCount: observations.count))
                continue
            }

            if observations.count > 1, multiPersonLogged < maxMultiPersonLogs {
                let sizes = withBoxes
                    .map { String(format: "%.3f×%.3f", $0.1.width, $0.1.height) }
                    .joined(separator: ", ")
                print(String(format: "[NiceShot] PoseSpike: t=%.2fs multi-person (%d): picked %.3f×%.3f from [%@]",
                             time, observations.count, selected.1.width, selected.1.height, sizes))
                multiPersonLogged += 1
                if multiPersonLogged == maxMultiPersonLogs {
                    print("[NiceShot] PoseSpike: (further multi-person frames suppressed from log)")
                }
            }

            samples.append(PoseSample(
                timestamp: time,
                joints: jointsDict(from: selected.0),
                boundingBox: selected.1,
                observationCount: observations.count
            ))
        }

        return samples
    }

    private func runPoseRequest(on cgImage: CGImage) async -> [VNHumanBodyPoseObservation] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            return []
        }
    }

    private func jointsDict(from obs: VNHumanBodyPoseObservation) -> [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint] {
        (try? obs.recognizedPoints(.all)) ?? [:]
    }

    private func boundingBox(for obs: VNHumanBodyPoseObservation) -> CGRect {
        guard let points = try? obs.recognizedPoints(.all) else { return .zero }
        let usable = points.values.filter { $0.confidence >= bboxConfidenceFloor }
        guard !usable.isEmpty else { return .zero }
        let xs = usable.map { $0.location.x }
        let ys = usable.map { $0.location.y }
        let minX = xs.min()!
        let maxX = xs.max()!
        let minY = ys.min()!
        let maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - P1 detector (iteration 2 rewrite)

    /// Earliest stable address position in the first 1.5s of the clip
    /// (proportional window for sub-4s clips). Stillness = stddev of
    /// lead-wrist + lead-shoulder + lead-hip y over a 300ms forward
    /// window below 0.015 (normalized space). Falls back to minimum-
    /// stddev frame so we always produce a candidate for inspection.
    private func detectP1(samples: [PoseSample], clipDuration: TimeInterval) -> PoseFrameCandidate? {
        let windowEnd = clipDuration < p1WindowShortClipThreshold
            ? clipDuration * p1WindowShortClipFraction
            : p1WindowSecondsNormal
        // V4.3 iter 3.1 — keep the full slot list (incl. unusable) so the
        // diagnostic logger can report body-detection rate within the window.
        let inWindow = samples.filter { $0.timestamp <= windowEnd }
        let inRange = inWindow.filter { $0.isUsable }
        guard !inRange.isEmpty else {
            logP1Diagnosis(inWindow: inWindow, windowEnd: windowEnd,
                           reason: "inRange empty — no body-detected frames in window")
            return nil
        }

        // For each candidate index, compute stddev of relevant joints
        // over a 3-sample forward window.
        //
        // V4.3 iter 3.1 — anchor filter relaxed from `wrist AND shoulder`
        // to `any of wrist/shoulder/hip`. The strict AND was rejecting
        // every P1-window frame on real address footage because the club
        // shaft occludes the lead wrist at address and Vision drops its
        // confidence below 0.3 even though body / shoulder / hip detect
        // cleanly. The `ys.count >= 4` data-sufficiency check below
        // continues to guarantee enough joint readings for a meaningful
        // stddev — no regression in calculation quality, just no longer
        // gated by an over-strict anchor requirement.
        var perFrame: [(idx: Int, sample: PoseSample, stddev: Double, confidence: Float)] = []
        for i in 0..<inRange.count {
            let endIdx = min(i + p1StillnessWindowSamples, inRange.count)
            guard endIdx - i >= 2 else { continue }

            let anchorWristConf = inRange[i].joints[leadWristJoint]?.confidence ?? 0
            let anchorShoulderConf = inRange[i].joints[leadShoulderJoint]?.confidence ?? 0
            let anchorHipConf = inRange[i].joints[leadHipJoint]?.confidence ?? 0
            let anchorConfs = [anchorWristConf, anchorShoulderConf, anchorHipConf]
                .filter { $0 >= jointConfidenceFloor }
            guard !anchorConfs.isEmpty else { continue }

            var ys: [Double] = []
            for sample in inRange[i..<endIdx] {
                for jointName in [leadWristJoint, leadShoulderJoint, leadHipJoint] {
                    if let pt = sample.joints[jointName], pt.confidence >= jointConfidenceFloor {
                        ys.append(Double(pt.location.y))
                    }
                }
            }
            guard ys.count >= 4 else { continue }

            let mean = ys.reduce(0.0, +) / Double(ys.count)
            let variance = ys.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(ys.count)
            let stddev = variance.squareRoot()
            // Confidence reflects only the lead-side joints actually
            // detected at the anchor — not artificially dragged down by
            // zeros from occluded joints.
            let frameConf = anchorConfs.reduce(0, +) / Float(anchorConfs.count)
            perFrame.append((i, inRange[i], stddev, frameConf))
        }

        guard !perFrame.isEmpty else {
            logP1Diagnosis(inWindow: inWindow, windowEnd: windowEnd,
                           reason: "perFrame empty — body frames exist but per-window confidence filters rejected all")
            return nil
        }

        // EARLIEST sub-threshold frame (was "latest" in iter 1 — this is
        // the key fix for "P1 found stillness during follow-through").
        if let earliest = perFrame.first(where: { $0.stddev < p1StillnessThreshold }) {
            return PoseFrameCandidate(
                timestamp: earliest.sample.timestamp,
                confidence: earliest.confidence,
                reasoning: String(format: "Earliest pre-swing stillness (stddev %.4f) at %.2fs",
                                  earliest.stddev, earliest.sample.timestamp)
            )
        }

        let minFrame = perFrame.min { $0.stddev < $1.stddev }!
        print(String(format: "[NiceShot] PoseSpike: P1 fallback: no stillness threshold met, using minimum stddev = %.4f at %.2fs",
                     minFrame.stddev, minFrame.sample.timestamp))
        return PoseFrameCandidate(
            timestamp: minFrame.sample.timestamp,
            confidence: minFrame.confidence,
            reasoning: String(format: "P1 fallback (no frame below %.3f); min stddev %.4f at %.2fs",
                              p1StillnessThreshold, minFrame.stddev, minFrame.sample.timestamp)
        )
    }

    /// V4.3 iter 3.1 — diagnostic-only logger that fires when `detectP1`
    /// returns nil. Surfaces which filter killed it (body detection rate,
    /// wrist+shoulder confidence rate, hip confidence rate, anchor-pass
    /// vs all-3-pass on the 300ms windows). Lets us target the fix
    /// precisely. Remove once the root cause is fixed.
    private func logP1Diagnosis(inWindow: [PoseSample],
                                windowEnd: TimeInterval,
                                reason: String) {
        let slotCount = inWindow.count
        let bodyDetected = inWindow.filter { $0.isUsable }.count

        let wristShoulderPass = inWindow.filter { sample in
            guard sample.isUsable,
                  let lw = sample.joints[leadWristJoint], lw.confidence >= jointConfidenceFloor,
                  let ls = sample.joints[leadShoulderJoint], ls.confidence >= jointConfidenceFloor
            else { return false }
            _ = (lw, ls)
            return true
        }.count

        let hipPass = inWindow.filter { sample in
            guard sample.isUsable,
                  let hip = sample.joints[leadHipJoint], hip.confidence >= jointConfidenceFloor
            else { return false }
            _ = hip
            return true
        }.count

        let usableOnly = inWindow.filter { $0.isUsable }
        var anchorPasses = 0
        var allThreePasses = 0
        var totalWindows = 0
        for i in 0..<usableOnly.count {
            let endIdx = min(i + p1StillnessWindowSamples, usableOnly.count)
            guard endIdx - i >= 2 else { continue }
            totalWindows += 1

            let aWristConf = usableOnly[i].joints[leadWristJoint]?.confidence ?? 0
            let aShoulderConf = usableOnly[i].joints[leadShoulderJoint]?.confidence ?? 0
            if aWristConf >= jointConfidenceFloor, aShoulderConf >= jointConfidenceFloor {
                anchorPasses += 1
            }

            let allPass = usableOnly[i..<endIdx].allSatisfy { sample in
                let lwc = sample.joints[leadWristJoint]?.confidence ?? 0
                let lsc = sample.joints[leadShoulderJoint]?.confidence ?? 0
                return lwc >= jointConfidenceFloor && lsc >= jointConfidenceFloor
            }
            if allPass { allThreePasses += 1 }
        }

        print(String(format: "[NiceShot] PoseSpike: P1 diagnosis — search window [0.00s, %.2fs], %d sample slots (%@)",
                     windowEnd, slotCount, reason))
        print("[NiceShot] PoseSpike: P1 diagnosis — frames with body detected: \(bodyDetected)/\(slotCount)")
        print("[NiceShot] PoseSpike: P1 diagnosis — frames passing wrist+shoulder conf 0.3: \(wristShoulderPass)/\(slotCount)")
        print("[NiceShot] PoseSpike: P1 diagnosis — frames with hip conf >= 0.3: \(hipPass)/\(slotCount)")
        print("[NiceShot] PoseSpike: P1 diagnosis — 300ms windows where anchor frame passes filter: \(anchorPasses)/\(totalWindows)")
        print("[NiceShot] PoseSpike: P1 diagnosis — 300ms windows where all 3 frames pass filter: \(allThreePasses)/\(totalWindows)")
    }

    // MARK: - P4 detector (iteration 2 rewrite)

    /// Frame in (P1 + 0.5s, P7 - 0.2s) where lead wrist Y has reached
    /// ≥90% of the maximum pre-impact wrist Y AND the previous 200ms
    /// shows wrist Y increasing AND the next 200ms shows wrist Y
    /// descending or staying flat. Earliest qualifier wins.
    /// Two fallbacks: max-Y in search window if no frame hits the height
    /// threshold; earliest height candidate if none satisfy directional
    /// context.
    private func detectP4(samples: [PoseSample],
                          p1Time: TimeInterval,
                          p7Time: TimeInterval) -> PoseFrameCandidate? {
        // Max wrist Y across full pre-impact range. Threshold = 90% of this.
        let preImpactWrists: [Double] = samples
            .filter { $0.timestamp <= p7Time && $0.isUsable }
            .compactMap { sample in
                guard let lw = sample.joints[leadWristJoint],
                      lw.confidence >= jointConfidenceFloor else { return nil }
                return Double(lw.location.y)
            }
        guard let maxPreImpactY = preImpactWrists.max(), maxPreImpactY > 0 else { return nil }
        let heightThreshold = maxPreImpactY * p4HeightFractionOfMax

        let searchStart = p1Time + p4SearchStartOffsetFromP1
        let searchEnd = p7Time - p4SearchEndOffsetFromP7
        guard searchEnd > searchStart else { return nil }

        let searchUsable: [(sample: PoseSample, y: Double, confidence: Float)] = samples
            .filter { $0.timestamp > searchStart && $0.timestamp < searchEnd && $0.isUsable }
            .compactMap { sample in
                guard let lw = sample.joints[leadWristJoint],
                      lw.confidence >= jointConfidenceFloor else { return nil }
                return (sample, Double(lw.location.y), lw.confidence)
            }
        guard !searchUsable.isEmpty else { return nil }

        let heightCandidates = searchUsable.filter { $0.y >= heightThreshold }

        if heightCandidates.isEmpty {
            // Fallback A: no frame at 90% max in search window. Use max-Y.
            let topByY = searchUsable.max(by: { $0.y < $1.y })!
            let pct = topByY.y / maxPreImpactY * 100
            print(String(format: "[NiceShot] PoseSpike: P4 fallback: no frame at 90%% max wrist height in search window, using max-Y at %.2fs",
                         topByY.sample.timestamp))
            return PoseFrameCandidate(
                timestamp: topByY.sample.timestamp,
                confidence: topByY.confidence,
                reasoning: String(format: "P4 fallback (no frame at 90%% max in search window); wrist at %.0f%% max at %.2fs",
                                  pct, topByY.sample.timestamp)
            )
        }

        // Directional context: 200ms before should be ascending, 200ms
        // after should be descending or flat. Strict on prior, allow
        // flat on after.
        var qualified: [(sample: PoseSample, y: Double, confidence: Float, pct: Double)] = []
        for c in heightCandidates {
            let priorYs = leadWristYs(in: samples,
                                       from: c.sample.timestamp - p4DirectionalWindowSeconds,
                                       to: c.sample.timestamp)
            let afterYs = leadWristYs(in: samples,
                                       from: c.sample.timestamp,
                                       to: c.sample.timestamp + p4DirectionalWindowSeconds)
            guard priorYs.count >= 2, afterYs.count >= 2 else { continue }

            let priorAscending = priorYs.last! > priorYs.first!
            let afterDescendingOrFlat = afterYs.last! <= afterYs.first!
            if priorAscending && afterDescendingOrFlat {
                let pct = c.y / maxPreImpactY * 100
                qualified.append((c.sample, c.y, c.confidence, pct))
            }
        }

        if qualified.isEmpty {
            // Fallback B: height candidates exist but none have proper
            // directional context. Use earliest height candidate.
            let earliest = heightCandidates.min(by: { $0.sample.timestamp < $1.sample.timestamp })!
            let pct = earliest.y / maxPreImpactY * 100
            print(String(format: "[NiceShot] PoseSpike: P4 fallback: no frame with proper directional context, using earliest height candidate at %.2fs",
                         earliest.sample.timestamp))
            return PoseFrameCandidate(
                timestamp: earliest.sample.timestamp,
                confidence: earliest.confidence,
                reasoning: String(format: "P4 fallback (no directional context); wrist at %.0f%% max at %.2fs",
                                  pct, earliest.sample.timestamp)
            )
        }

        // Earliest qualifier wins (first frame at the top).
        let chosen = qualified.min(by: { $0.sample.timestamp < $1.sample.timestamp })!
        return PoseFrameCandidate(
            timestamp: chosen.sample.timestamp,
            confidence: chosen.confidence,
            reasoning: String(format: "Lead wrist at %.0f%% max height, ramping up before, descending after, at %.2fs",
                              chosen.pct, chosen.sample.timestamp)
        )
    }

    /// Collect lead-wrist y values in a time range, ignoring frames where
    /// the wrist confidence is below the floor.
    private func leadWristYs(in samples: [PoseSample],
                             from startTime: TimeInterval,
                             to endTime: TimeInterval) -> [Double] {
        samples
            .filter { $0.timestamp >= startTime && $0.timestamp <= endTime && $0.isUsable }
            .compactMap { sample in
                guard let lw = sample.joints[leadWristJoint],
                      lw.confidence >= jointConfidenceFloor else { return nil }
                return Double(lw.location.y)
            }
    }

    // MARK: - P10 detector (iteration 3 — replaces P8)

    /// Finish Position. Mirror of P1: earliest sustained stillness, but
    /// in the LAST 1.5s of the clip rather than the first 1.5s, with a
    /// 0.5s buffer past P7 to ensure we're well into the follow-through.
    /// Stillness threshold is looser than P1's (0.020 vs 0.015) because
    /// golfers wobble at the finish more than at address.
    ///
    /// Edge cases:
    ///   • post-impact < 0.3s → return nil (no p10.jpg written)
    ///   • search window < 0.5s → last frame of clip as fallback
    ///   • no frame below threshold → minimum-stddev frame fallback
    private func detectP10(samples: [PoseSample],
                           p7Time: TimeInterval,
                           clipDuration: TimeInterval) -> PoseFrameCandidate? {
        let postImpactLength = clipDuration - p7Time
        if postImpactLength < p10MinPostImpactSeconds {
            print(String(format: "[NiceShot] PoseSpike: P10 unavailable - post-impact window too short (%.2fs)",
                         postImpactLength))
            return nil
        }

        let searchStart = max(clipDuration - p10SearchWindowSeconds, p7Time + p10BufferAfterP7)
        let searchEnd = clipDuration
        let searchWindowLength = searchEnd - searchStart

        if searchWindowLength < p10MinSearchWindowSeconds {
            let lastSample = samples.last { $0.isUsable }
            let ts = lastSample?.timestamp ?? max(clipDuration - 0.01, p7Time)
            let conf = lastSample?.joints[leadWristJoint]?.confidence ?? 0
            print(String(format: "[NiceShot] PoseSpike: P10 fallback: post-impact window too short (%.2fs), using last frame at %.2fs",
                         searchWindowLength, ts))
            return PoseFrameCandidate(
                timestamp: ts,
                confidence: conf,
                reasoning: String(format: "P10 fallback (window %.2fs); using last frame at %.2fs", searchWindowLength, ts)
            )
        }

        let inRange = samples.filter { $0.timestamp >= searchStart && $0.timestamp <= searchEnd && $0.isUsable }

        var perFrame: [(sample: PoseSample, stddev: Double, confidence: Float)] = []
        for i in 0..<inRange.count {
            let endIdx = min(i + p10StillnessWindowSamples, inRange.count)
            guard endIdx - i >= 2 else { continue }

            let leadWristConf = inRange[i].joints[leadWristJoint]?.confidence ?? 0
            let leadShoulderConf = inRange[i].joints[leadShoulderJoint]?.confidence ?? 0
            guard leadWristConf >= jointConfidenceFloor,
                  leadShoulderConf >= jointConfidenceFloor else { continue }

            var ys: [Double] = []
            for sample in inRange[i..<endIdx] {
                for jointName in [leadWristJoint, leadShoulderJoint, leadHipJoint] {
                    if let pt = sample.joints[jointName], pt.confidence >= jointConfidenceFloor {
                        ys.append(Double(pt.location.y))
                    }
                }
            }
            guard ys.count >= 4 else { continue }

            let mean = ys.reduce(0.0, +) / Double(ys.count)
            let variance = ys.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(ys.count)
            let stddev = variance.squareRoot()
            let frameConf = (leadWristConf + leadShoulderConf) / 2
            perFrame.append((inRange[i], stddev, frameConf))
        }

        guard !perFrame.isEmpty else {
            // Window present but every frame was filtered out (low confidence,
            // joint dropouts). Fall back to last usable frame so we still
            // produce a candidate for inspection.
            let lastSample = samples.last { $0.isUsable }
            let ts = lastSample?.timestamp ?? max(clipDuration - 0.01, p7Time)
            let conf = lastSample?.joints[leadWristJoint]?.confidence ?? 0
            print(String(format: "[NiceShot] PoseSpike: P10 fallback: no usable frames in search window, using last frame at %.2fs", ts))
            return PoseFrameCandidate(
                timestamp: ts,
                confidence: conf,
                reasoning: String(format: "P10 fallback (no usable frames in window); last frame at %.2fs", ts)
            )
        }

        if let earliest = perFrame.first(where: { $0.stddev < p10StillnessThreshold }) {
            return PoseFrameCandidate(
                timestamp: earliest.sample.timestamp,
                confidence: earliest.confidence,
                reasoning: String(format: "Earliest post-swing stillness (stddev %.4f) at %.2fs within clip",
                                  earliest.stddev, earliest.sample.timestamp)
            )
        }

        let minFrame = perFrame.min { $0.stddev < $1.stddev }!
        print(String(format: "[NiceShot] PoseSpike: P10 fallback: no stillness threshold met, using minimum stddev = %.4f at %.2fs",
                     minFrame.stddev, minFrame.sample.timestamp))
        return PoseFrameCandidate(
            timestamp: minFrame.sample.timestamp,
            confidence: minFrame.confidence,
            reasoning: String(format: "P10 fallback (no frame below %.3f); min stddev %.4f at %.2fs",
                              p10StillnessThreshold, minFrame.stddev, minFrame.sample.timestamp)
        )
    }

    // MARK: - P7 (passthrough)

    private func makeP7(samples: [PoseSample], time: TimeInterval) -> PoseFrameCandidate? {
        let sample = closestSample(to: time, in: samples)
        let lw = sample?.joints[leadWristJoint]
        return PoseFrameCandidate(
            timestamp: time,
            confidence: lw?.confidence ?? 0,
            reasoning: "Impact (from existing audio detection)"
        )
    }

    private func closestSample(to time: TimeInterval, in samples: [PoseSample]) -> PoseSample? {
        samples.min { abs($0.timestamp - time) < abs($1.timestamp - time) }
    }

    private func stillLabel(for label: String, candidate: PoseFrameCandidate) -> String {
        let positionName: String
        switch label {
        case "p1":  positionName = "P1 — Address"
        case "p4":  positionName = "P4 — Top of Backswing"
        case "p7":  positionName = "P7 — Impact"
        case "p10": positionName = "P10 — Finish"
        default:    positionName = label.uppercased()
        }
        return String(format: "%@ — %.3fs — conf %.2f", positionName, candidate.timestamp, candidate.confidence)
    }

    // MARK: - Annotated still output

    private func saveAnnotatedStill(asset: AVURLAsset,
                                    time: TimeInterval,
                                    label: String,
                                    sample: PoseSample?,
                                    to url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        let (cgImage, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))

        let annotated = drawOverlay(on: cgImage, sample: sample, label: label)
        guard let data = annotated.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "PoseAnalyzer", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }
        try data.write(to: url, options: .atomic)
    }

    private func drawOverlay(on cgImage: CGImage, sample: PoseSample?, label: String) -> UIImage {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))

            // Yellow bbox of selected person.
            if let s = sample, let bbox = s.boundingBox, bbox.width > 0, bbox.height > 0 {
                let rect = CGRect(
                    x: bbox.minX * size.width,
                    y: (1.0 - bbox.maxY) * size.height,
                    width: bbox.width * size.width,
                    height: bbox.height * size.height
                )
                UIColor.systemYellow.setStroke()
                let path = UIBezierPath(rect: rect)
                path.lineWidth = max(4, size.height / 220)
                path.stroke()
            }

            // Joint dots: green = confident, gray = low-confidence.
            if let s = sample {
                let dotRadius = max(6, size.height / 120)
                for (_, point) in s.joints {
                    let cx = point.location.x * size.width
                    let cy = (1.0 - point.location.y) * size.height
                    let color: UIColor = point.confidence >= 0.3
                        ? .systemGreen
                        : UIColor.gray.withAlphaComponent(0.7)
                    color.setFill()
                    UIBezierPath(
                        arcCenter: CGPoint(x: cx, y: cy),
                        radius: dotRadius,
                        startAngle: 0,
                        endAngle: 2 * .pi,
                        clockwise: true
                    ).fill()
                    UIColor.black.withAlphaComponent(0.45).setStroke()
                    let outline = UIBezierPath(
                        arcCenter: CGPoint(x: cx, y: cy),
                        radius: dotRadius,
                        startAngle: 0,
                        endAngle: 2 * .pi,
                        clockwise: true
                    )
                    outline.lineWidth = 1
                    outline.stroke()
                }
            } else {
                let bannerHeight = size.height * 0.1
                let bannerRect = CGRect(
                    x: 0,
                    y: size.height * 0.5 - bannerHeight / 2,
                    width: size.width,
                    height: bannerHeight
                )
                UIColor.systemRed.withAlphaComponent(0.85).setFill()
                UIBezierPath(rect: bannerRect).fill()
                drawCenteredText("NO BODY DETECTED",
                                 in: bannerRect,
                                 fontSize: size.height / 24,
                                 color: .white)
            }

            let labelHeight = size.height * 0.06
            let labelRect = CGRect(x: 0, y: 0, width: size.width, height: labelHeight)
            UIColor.black.withAlphaComponent(0.72).setFill()
            UIBezierPath(rect: labelRect).fill()
            drawCenteredText(label,
                             in: labelRect,
                             fontSize: size.height / 32,
                             color: .white)
        }
    }

    private func drawCenteredText(_ text: String,
                                  in rect: CGRect,
                                  fontSize: CGFloat,
                                  color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textHeight = attributed.size().height
        let textRect = CGRect(
            x: rect.minX,
            y: rect.midY - textHeight / 2,
            width: rect.width,
            height: textHeight
        )
        attributed.draw(in: textRect)
    }
}
