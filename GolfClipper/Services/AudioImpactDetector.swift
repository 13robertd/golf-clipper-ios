// AudioImpactDetector.swift
//
// =============================================================================
// V3 — ENERGY-RATIO DETECTOR FOR LONG VIDEOS
// =============================================================================
//
// V1's "any window above a fixed amplitude threshold = swing" worked for
// quiet single-swing clips but fell over on noisy 5-min driving range
// videos. V2 added confidence scoring (PNR / sharpness / decay) which
// helped a bit but kept absolute amplitudes in the loop.
//
// V3 reframes detection in terms of *relative* energy:
//
//   1. Decode audio → Float32 mono @ 44.1 kHz, chunk by chunk
//      (one CMSampleBuffer at a time; each is released before the next,
//       so peak memory stays under a few MB regardless of video length)
//   2. For each ~20 ms window (882 samples), compute RMS via vDSP
//      (Accelerate framework — 10-50× faster than a manual loop)
//   3. For each window i, compute the ENERGY RATIO:
//        ratio[i] = rms[i] / max(mean(rms[i-10 .. i-1]), epsilon)
//      Naturally adapts to background noise: a swing's transient stands
//      out 5-10× against its preceding ~200 ms, even in a noisy room.
//   4. Adaptive threshold: median(ratios) + multiplier × stddev(ratios)
//      where `multiplier` comes from the preset (Catch More 2.0,
//      Recommended 2.5) or a user override.
//   5. Two-pass dedup:
//      A — within each 500 ms slice, keep only the highest-ratio peak
//          (collapses the multiple sub-peaks one impact produces:
//          hit + ground contact + echo)
//      B — "loudest wins" cooldown: greedy-accept by ratio descending,
//          rejecting any candidate within `minimumSpacingSeconds` of an
//          already-accepted one (default 6.0 s — keeps two real swings
//          from merging while killing micro-duplicates)
//
// Diagnostic logging stays in for now (the spec asked for it during the
// long-video bring-up). Strip it once the algorithm is proven on real
// videos.
//
// Manual clipping is unaffected — it doesn't go through this pipeline.
// =============================================================================

import Foundation
import AVFoundation
import Accelerate
import Darwin

// MARK: - Public types

/// One scored window above the adaptive threshold, surfaced to the
/// debug screen so the user can see exactly why each event made or
/// didn't make the cut.
struct ImpactCandidate: Codable, Hashable, Identifiable {
    var id: Double { time }
    let time: Double
    let rms: Double
    let energyRatio: Double
    let threshold: Double
    let accepted: Bool
    let rejectionReason: String?
}

/// Diagnostic stats from one detection run. Drives the new Settings →
/// Debug stat card so detection can be tuned with real numbers in hand.
struct DetectionStats: Codable, Equatable {
    let videoDurationSeconds: Double
    let totalWindowsAnalyzed: Int
    /// Median of the energy-ratio signal — the "noise floor" in
    /// ratio space. Real impacts produce ratios well above this.
    let medianRatio: Double
    let stddevRatio: Double
    let adaptiveThreshold: Double
    let multiplier: Double
    let rawPeakCount: Int
    let after500msDedup: Int
    let afterMinSpacing: Int
    let processingTimeSeconds: Double
}

struct ImpactDetectionResult {
    /// Final accepted impact timestamps (seconds), sorted ascending.
    let impactTimestamps: [Double]
    /// All windows that crossed the adaptive threshold, with their
    /// final accept/reject verdict.
    let candidates: [ImpactCandidate]
    /// Run-level diagnostics for the debug screen.
    let stats: DetectionStats
    /// V3.8 — strongest energy-ratio window across the WHOLE video,
    /// regardless of whether it crossed threshold. Powers the
    /// short-video fallback in AppState.processVideo: when an under-15s
    /// recording produces zero clips, we use this as the impact moment.
    let loudestWindowTime: Double?
    let maxEnergyRatio: Double
}

enum AudioImpactError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "This video has no audio track. Use Manual Clip."
        case .readerFailed(let why):
            return "Could not read audio (\(why))."
        case .decodeFailed:
            return "Could not decode audio samples."
        }
    }
}

// MARK: - Detector

final class AudioImpactDetector {

    private let analysisSampleRate: Double = 44_100
    /// 20 ms windows for energy analysis (882 samples @ 44.1 kHz).
    private let windowSampleCount: Int = 882

    /// Number of preceding windows averaged for the energy-ratio
    /// denominator. ~200 ms history.
    private static let prevWindowsForRatio = 10

    /// Pass-A dedup window — collapses an impact's sub-peaks (hit,
    /// ground contact, echo) into one event.
    private static let dedupWindowSeconds = 0.5

    /// Floor on the ratio denominator. Prevents silence-amplification
    /// (current sample's tiny noise / silence's tinier noise = ∞).
    private static let denominatorFloor: Float = 0.01

    func detectImpacts(in video: ImportedVideo,
                       settings: DetectionSettings,
                       progress: @escaping (Double) -> Void = { _ in }) async throws -> ImpactDetectionResult {

        let startTime = Date()
        let memBefore = memoryUsageMB()
        print("[NiceShot] Video duration: \(String(format: "%.2f", video.duration)) seconds")
        print("[NiceShot] Memory usage before processing: \(String(format: "%.1f", memBefore)) MB")

        // ---- Pass 1: read audio + per-window RMS via vDSP ---------------------
        let windows = try await readAndComputeRMS(for: video, progress: progress)
        let memAfterDecode = memoryUsageMB()
        print("[NiceShot] Total windows analyzed: \(windows.count)")
        print("[NiceShot] Memory usage after decode: \(String(format: "%.1f", memAfterDecode)) MB")

        // ---- Pass 2: energy ratios -------------------------------------------
        let ratioWindows = computeEnergyRatios(windows)

        // ---- Pass 3: adaptive threshold --------------------------------------
        let multiplier = settings.effectiveMultiplier
        let ratiosOnly = ratioWindows.map { Double($0.energyRatio) }
        let medianRatio = median(ratiosOnly)
        let meanRatio = ratiosOnly.isEmpty ? 0 : ratiosOnly.reduce(0, +) / Double(ratiosOnly.count)
        let stddevRatio = stddev(ratiosOnly, mean: meanRatio)
        let threshold = medianRatio + multiplier * stddevRatio

        // V3.8 — strongest window across the WHOLE recording, regardless
        // of threshold. Logged so you can compare "what was actually the
        // loudest moment" to the threshold at a glance, and exposed on
        // the result so the short-video fallback can use it.
        let loudestWindow = ratioWindows.max { Double($0.energyRatio) < Double($1.energyRatio) }
        let maxEnergyRatio = loudestWindow.map { Double($0.energyRatio) } ?? 0
        let loudestWindowTime = loudestWindow.map { $0.time }

        print("[NiceShot] Multiplier: \(multiplier)")
        print("[NiceShot] Median ratio (noise floor): \(String(format: "%.3f", medianRatio))")
        print("[NiceShot] Stddev ratio: \(String(format: "%.3f", stddevRatio))")
        print("[NiceShot] Adaptive threshold: \(String(format: "%.3f", threshold))")
        if let t = loudestWindowTime {
            print("[NiceShot] Max peak ratio: \(String(format: "%.3f", maxEnergyRatio)) at \(String(format: "%.2fs", t)) (threshold \(String(format: "%.3f", threshold)))")
        } else {
            print("[NiceShot] Max peak ratio: n/a (no windows)")
        }

        // ---- Pass 4: raw peaks ------------------------------------------------
        let rawPeaks = ratioWindows.filter { Double($0.energyRatio) > threshold }
        print("[NiceShot] Peaks above threshold: \(rawPeaks.count) \(formatTimestamps(rawPeaks.map { $0.time }))")

        // ---- Pass 5a: 500 ms dedup -------------------------------------------
        let dedupedPeaks = collapseDuplicates(rawPeaks,
                                              windowDuration: Self.dedupWindowSeconds)
        print("[NiceShot] Peaks after 500ms dedup: \(dedupedPeaks.count) \(formatTimestamps(dedupedPeaks.map { $0.time }))")

        // ---- Pass 5b: min-spacing cooldown -----------------------------------
        let acceptedTimes = applyMinSpacing(dedupedPeaks,
                                            minSpacing: settings.minimumSpacingSeconds)
        print("[NiceShot] Peaks after min spacing filter: \(acceptedTimes.count) \(formatTimestamps(acceptedTimes))")

        // ---- Build candidate list for the debug screen -----------------------
        let acceptedSet = Set(acceptedTimes.map { roundedKey($0) })
        let dedupedSet  = Set(dedupedPeaks.map { roundedKey($0.time) })
        let topRawForDebug = rawPeaks
            .sorted { $0.energyRatio > $1.energyRatio }
            .prefix(60)
            .sorted { $0.time < $1.time }

        var candidates: [ImpactCandidate] = []
        for w in topRawForDebug {
            let key = roundedKey(w.time)
            let accepted = acceptedSet.contains(key)
            let inDeduped = dedupedSet.contains(key)
            let reason: String?
            if accepted {
                reason = nil
            } else if !inDeduped {
                reason = "Duplicate within 500ms"
            } else {
                reason = "Too close to a stronger impact"
            }
            candidates.append(ImpactCandidate(
                time: w.time,
                rms: Double(w.rms),
                energyRatio: Double(w.energyRatio),
                threshold: threshold,
                accepted: accepted,
                rejectionReason: reason
            ))
        }

        let processingTime = Date().timeIntervalSince(startTime)
        let memAfter = memoryUsageMB()
        print("[NiceShot] Processing time: \(String(format: "%.2f", processingTime)) seconds")
        print("[NiceShot] Memory usage after processing: \(String(format: "%.1f", memAfter)) MB")

        let stats = DetectionStats(
            videoDurationSeconds: video.duration,
            totalWindowsAnalyzed: windows.count,
            medianRatio: medianRatio,
            stddevRatio: stddevRatio,
            adaptiveThreshold: threshold,
            multiplier: multiplier,
            rawPeakCount: rawPeaks.count,
            after500msDedup: dedupedPeaks.count,
            afterMinSpacing: acceptedTimes.count,
            processingTimeSeconds: processingTime
        )

        return ImpactDetectionResult(
            impactTimestamps: acceptedTimes.sorted(),
            candidates: candidates,
            stats: stats,
            loudestWindowTime: loudestWindowTime,
            maxEnergyRatio: maxEnergyRatio
        )
    }

    // MARK: - Pass 1: decode + RMS

    /// Internal per-window record. Filled across pass 1 (rms) and pass 2
    /// (energyRatio). Not exposed publicly — consumers get
    /// ImpactCandidate / DetectionStats instead.
    private struct AudioWindow {
        let time: Double
        let rms: Float
        var energyRatio: Float = 0
    }

    private func readAndComputeRMS(for video: ImportedVideo,
                                   progress: @escaping (Double) -> Void) async throws -> [AudioWindow] {

        let asset = AVURLAsset(url: video.localFileURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            print("[NiceShot] Audio track found: no")
            throw AudioImpactError.noAudioTrack
        }
        print("[NiceShot] Audio track found: yes")
        print("[NiceShot] Audio format: \(Int(analysisSampleRate)) Hz mono Float32")
        print("[NiceShot] Analysis window size: \(windowSampleCount) samples (\(String(format: "%.1f", Double(windowSampleCount) / analysisSampleRate * 1000)) ms)")

        let totalDuration = video.duration

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioImpactError.readerFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             analysisSampleRate,
            AVNumberOfChannelsKey:       1,
            AVLinearPCMBitDepthKey:      32,
            AVLinearPCMIsFloatKey:       true,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack,
                                                   outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw AudioImpactError.readerFailed("cannot add output")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw AudioImpactError.readerFailed(reader.error?.localizedDescription ?? "startReading")
        }

        var windows: [AudioWindow] = []
        windows.reserveCapacity(Int(totalDuration * analysisSampleRate / Double(windowSampleCount)) + 16)
        var pending: [Float] = []           // partial window carried across CMSampleBuffers
        pending.reserveCapacity(windowSampleCount)
        var samplesProcessed: Int64 = 0
        var lastReportedProgress: Double = -1

        // Drain CMSampleBuffers one at a time. Each is released before the
        // next is requested, so peak audio memory is one buffer's worth
        // (a few MB), regardless of video length.
        while reader.status == .reading,
              let sampleBuffer = trackOutput.copyNextSampleBuffer() {

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            let totalLength = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = totalLength / MemoryLayout<Float>.size

            // Read straight into a Float32 array — no UInt8 detour.
            var floats = [Float](repeating: 0, count: sampleCount)
            let copyStatus = floats.withUnsafeMutableBufferPointer { buf -> OSStatus in
                guard let base = buf.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(blockBuffer,
                                                  atOffset: 0,
                                                  dataLength: totalLength,
                                                  destination: base)
            }
            CMSampleBufferInvalidate(sampleBuffer)
            guard copyStatus == kCMBlockBufferNoErr else { continue }

            // Slice into windows (handles partial windows across buffers).
            var localIdx = 0
            while localIdx < floats.count {
                let needed = windowSampleCount - pending.count
                let available = floats.count - localIdx
                let take = min(needed, available)

                pending.append(contentsOf: floats[localIdx..<(localIdx + take)])
                localIdx += take

                if pending.count >= windowSampleCount {
                    var rms: Float = 0
                    pending.withUnsafeBufferPointer { buf in
                        // RMS = sqrt(mean(x²)). vDSP_rmsqv does exactly this
                        // on hardware-accelerated SIMD.
                        vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(windowSampleCount))
                    }
                    let timeSec = Double(samplesProcessed) / analysisSampleRate
                    windows.append(AudioWindow(time: timeSec, rms: rms))
                    samplesProcessed += Int64(windowSampleCount)
                    pending.removeAll(keepingCapacity: true)
                }
            }

            // Throttle progress callbacks to ~100 / video.
            if totalDuration > 0 {
                let fraction = min(1.0, Double(samplesProcessed) / analysisSampleRate / totalDuration)
                if fraction - lastReportedProgress >= 0.01 {
                    progress(fraction)
                    lastReportedProgress = fraction
                }
            }
        }

        if reader.status == .failed {
            throw AudioImpactError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        progress(1.0)
        print("[NiceShot] Total audio samples processed: \(samplesProcessed)")
        return windows
    }

    // MARK: - Pass 2: energy ratios

    private func computeEnergyRatios(_ windows: [AudioWindow]) -> [AudioWindow] {
        guard !windows.isEmpty else { return windows }
        var result = windows
        // Rolling sum of the last `prevWindowsForRatio` RMS values.
        var rollingSum: Float = 0
        let n = Self.prevWindowsForRatio
        for i in result.indices {
            let prevCount = min(i, n)
            let avgPrev: Float = prevCount > 0
                ? max(rollingSum / Float(prevCount), Self.denominatorFloor)
                : Self.denominatorFloor
            result[i].energyRatio = result[i].rms / avgPrev

            // Slide the window: add this rms, drop the one falling out the back.
            rollingSum += result[i].rms
            if i >= n {
                rollingSum -= result[i - n].rms
            }
        }
        return result
    }

    // MARK: - Stats helpers

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private func stddev(_ values: [Double], mean m: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let sumSq = values.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
        return (sumSq / Double(values.count - 1)).squareRoot()
    }

    // MARK: - Two-pass filtering

    /// Pass A — within each `windowDuration` slice, keep the highest-ratio
    /// peak. Collapses the cluster of windows from one impact (hit, ground
    /// contact, echo) into a single event.
    private func collapseDuplicates(_ peaks: [AudioWindow],
                                    windowDuration: Double) -> [AudioWindow] {
        guard !peaks.isEmpty else { return [] }
        var result: [AudioWindow] = []
        var current: AudioWindow = peaks[0]
        for peak in peaks.dropFirst() {
            if peak.time - current.time < windowDuration {
                if peak.energyRatio > current.energyRatio {
                    current = peak
                }
            } else {
                result.append(current)
                current = peak
            }
        }
        result.append(current)
        return result
    }

    /// Pass B — "loudest wins" cooldown. Sort by ratio descending,
    /// greedy-accept each peak only if it's at least `minSpacing` from
    /// every accepted peak. Returns timestamps sorted ascending.
    private func applyMinSpacing(_ peaks: [AudioWindow],
                                 minSpacing: Double) -> [Double] {
        guard !peaks.isEmpty else { return [] }
        let byRatio = peaks.sorted { $0.energyRatio > $1.energyRatio }
        var accepted: [Double] = []
        for peak in byRatio {
            let conflicts = accepted.contains { abs($0 - peak.time) < minSpacing }
            if !conflicts {
                accepted.append(peak.time)
            }
        }
        return accepted.sorted()
    }

    // MARK: - Misc

    private func roundedKey(_ time: Double) -> Int {
        Int((time * 1000.0).rounded())  // 1 ms resolution — enough to dedupe by time
    }

    private func memoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    // MARK: - Diagnostic helpers

    /// V3.7 — formats a list of impact times as "[1.23s, 4.56s, 7.89s]"
    /// for the per-pass peak logs. Empty list renders as "[]" so the
    /// pipeline stage where peaks vanish is obvious in the console.
    private func formatTimestamps(_ times: [Double]) -> String {
        let body = times.map { String(format: "%.2fs", $0) }.joined(separator: ", ")
        return "[" + body + "]"
    }
}
