// AudioImpactDetector.swift
//
// Core swing-detection engine.
//
// =============================================================================
// V2 — FALSE-POSITIVE REDUCTION
// =============================================================================
//
// The V1 rule was simple: "any window above a fixed amplitude threshold is a
// swing." That worked for clean single-swing clips but produced lots of false
// positives on longer videos (voices, claps, club-on-mat noise, wind).
//
// V2 SCORES each loud window using several features instead:
//
//   1. Peak amplitude (raw 0..1)
//   2. Local noise floor — median amplitude of the previous ~2 seconds
//      (excluding the immediate ~100 ms before, which is part of the attack)
//   3. Peak-to-noise ratio (PNR) = peak / noise floor
//   4. Sharpness (attack)        = peak − max amplitude over the prev ~115 ms
//   5. Decay quality             = fraction of next ~250 ms below 50 % of peak
//
// A real ball strike has: high PNR (loud vs ambient), high sharpness
// (sudden onset), and high decay quality (clicks fade quickly). Voices,
// wind, and club whooshes fail on at least one of these.
//
// We combine the features into a composite confidence score (0..1) and
// compare against thresholds bundled into the user-selected preset
// (Catch More / Recommended).
//
// Pipeline:
//   1. Decode audio to 32-bit float mono PCM at 44.1 kHz.
//   2. Pass 1: slide a 1024-sample (~23 ms) window, record peak per window.
//   3. Pass 2: for each peak above the preset's amplitude floor, compute
//      noise floor / PNR / sharpness / decay / confidence. Reject if any
//      hard floor or composite threshold is missed.
//   4. "Loudest wins" cooldown: sort surviving candidates by confidence
//      descending, greedy-accept those at least `minimumSpacingSeconds`
//      from any already-accepted impact. The dropped ones stay in the
//      candidate list with reason "Too close to a stronger impact" so the
//      debug screen can show them.
//
// Manual clipping is unaffected — it doesn't go through this pipeline.
// =============================================================================

import Foundation
import AVFoundation
import CoreMedia

/// One per-window peak measurement (the raw signal envelope at ~23 ms resolution).
struct AudioPeak: Codable, Hashable {
    let time: Double
    let amplitude: Double
}

/// A scored candidate: a peak that passed the hard amplitude floor and was
/// classified accepted or rejected. Surfaced in the debug screen so the
/// user can see WHY each loud event made or didn't make the cut.
struct ImpactCandidate: Codable, Hashable, Identifiable {
    var id: Double { time }
    let time: Double
    let peakAmplitude: Double
    let noiseFloor: Double
    let pnr: Double
    let sharpness: Double
    let decayScore: Double
    let confidence: Double
    let accepted: Bool
    let rejectionReason: String?
}

struct ImpactDetectionResult {
    /// Final accepted impact timestamps (seconds), sorted ascending.
    let impactTimestamps: [Double]
    /// All peaks above the preset's amplitude floor, with scoring + verdict.
    let candidates: [ImpactCandidate]
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

final class AudioImpactDetector {

    // We resample to 44.1 kHz mono so analysis is consistent across devices.
    private let analysisSampleRate: Double = 44_100

    // ~23 ms window. Short enough to localise sharp transients, long
    // enough that the per-window peak is stable.
    private let windowSampleCount: Int = 1024

    /// Time covered by one window, in seconds.
    private var windowDuration: Double { Double(windowSampleCount) / analysisSampleRate }

    /// Run the full detection pipeline.
    /// - Parameters:
    ///   - video: imported video to analyse
    ///   - settings: user-tunable detection settings
    ///   - progress: 0.0…1.0 progress callback (audio decoded fraction)
    func detectImpacts(in video: ImportedVideo,
                       settings: DetectionSettings,
                       progress: @escaping (Double) -> Void = { _ in }) async throws -> ImpactDetectionResult {

        // ===== Pass 1: decode audio and build per-window peak envelope. =====
        let peaks = try await readPeakEnvelope(for: video, progress: progress)

        // ===== Pass 2: score every peak above the preset's amplitude floor. =====
        let preset = settings.preset
        let nWindowsExclude  = max(1, Int(0.10 / windowDuration))   // ~5 windows  (100 ms)
        let nWindowsLookback = max(1, Int(2.00 / windowDuration))   // ~86 windows (2 s)
        let nWindowsSharp    = 5                                    // ~115 ms
        let nWindowsDecay    = max(1, Int(0.25 / windowDuration))   // ~11 windows (250 ms)

        // Pair each candidate with its peaks-array index so the cooldown
        // step can dedupe by index (avoids fragile Double equality).
        struct ScoredCandidate {
            let peakIndex: Int
            let candidate: ImpactCandidate
        }
        var scored: [ScoredCandidate] = []
        scored.reserveCapacity(64)

        for (i, p) in peaks.enumerated() {
            guard p.amplitude >= preset.minPeakAmplitude else { continue }

            // --- Local noise floor: median of peaks in [-2.0 s, -0.1 s]. ---
            let lo = max(0, i - nWindowsLookback - nWindowsExclude)
            let hi = max(0, i - nWindowsExclude)
            var noiseFloor: Double = 0.001
            if hi > lo {
                var amps = peaks[lo..<hi].map { $0.amplitude }
                amps.sort()
                let mid = amps.count / 2
                noiseFloor = amps.count.isMultiple(of: 2)
                    ? (amps[mid - 1] + amps[mid]) / 2.0
                    : amps[mid]
            }
            noiseFloor = max(noiseFloor, 0.001)

            // --- Peak-to-noise ratio. ---
            let pnr = p.amplitude / noiseFloor

            // --- Sharpness: how much louder than the previous ~5 windows. ---
            let sLo = max(0, i - nWindowsSharp)
            var prevMax: Double = 0
            if sLo < i {
                prevMax = peaks[sLo..<i].map { $0.amplitude }.max() ?? 0
            }
            let sharpness = p.amplitude - prevMax

            // --- Decay: fraction of next ~250 ms below 50 % of peak. ---
            let dHi = min(peaks.count, i + 1 + nWindowsDecay)
            var decayScore: Double = 0
            if dHi > i + 1 {
                let half = p.amplitude * 0.5
                let nextSlice = peaks[(i + 1)..<dHi]
                let belowCount = nextSlice.filter { $0.amplitude < half }.count
                decayScore = Double(belowCount) / Double(nextSlice.count)
            }

            // --- Composite confidence (0..1). ---
            // PNR / sharpness are normalised against "comfortable pass" levels
            // (1.5× and 2× the preset minimums). Amplitude has small weight
            // because absolute loudness depends on the recording device.
            let pnrScore   = min(1.0, pnr / max(preset.minPNR * 1.5, 0.001))
            let sharpScore = min(1.0, max(0, sharpness) / max(preset.minSharpness * 2.0, 0.001))
            let ampScore   = min(1.0, p.amplitude / 0.6)
            let confidence = 0.40 * pnrScore
                           + 0.30 * sharpScore
                           + 0.20 * decayScore
                           + 0.10 * ampScore

            // --- Reject reasons (priority order: hard floors first). ---
            var rejection: String? = nil
            if pnr < preset.minPNR {
                rejection = String(format: "Low PNR (%.1f×)", pnr)
            } else if sharpness < preset.minSharpness {
                rejection = String(format: "Not sharp (Δ%.2f)", sharpness)
            } else if confidence < preset.minConfidence {
                rejection = String(format: "Low confidence (%.2f)", confidence)
            }

            let candidate = ImpactCandidate(
                time: p.time,
                peakAmplitude: p.amplitude,
                noiseFloor: noiseFloor,
                pnr: pnr,
                sharpness: sharpness,
                decayScore: decayScore,
                confidence: confidence,
                accepted: rejection == nil,
                rejectionReason: rejection
            )
            scored.append(ScoredCandidate(peakIndex: i, candidate: candidate))
        }

        // ===== Cooldown: keep the strongest non-conflicting set. =====
        let initiallyAccepted = scored.filter { $0.candidate.accepted }
        let sortedByScore = initiallyAccepted.sorted {
            $0.candidate.confidence > $1.candidate.confidence
        }

        var acceptedIndices = Set<Int>()
        var acceptedTimes:   [Double] = []
        for sc in sortedByScore {
            let conflicts = acceptedTimes.contains {
                abs($0 - sc.candidate.time) < settings.minimumSpacingSeconds
            }
            if !conflicts {
                acceptedIndices.insert(sc.peakIndex)
                acceptedTimes.append(sc.candidate.time)
            }
        }

        // ===== Build final candidate list with cooldown rejections marked. =====
        var finalCandidates: [ImpactCandidate] = []
        finalCandidates.reserveCapacity(scored.count)
        for sc in scored {
            let c = sc.candidate
            if c.accepted && !acceptedIndices.contains(sc.peakIndex) {
                finalCandidates.append(ImpactCandidate(
                    time: c.time,
                    peakAmplitude: c.peakAmplitude,
                    noiseFloor: c.noiseFloor,
                    pnr: c.pnr,
                    sharpness: c.sharpness,
                    decayScore: c.decayScore,
                    confidence: c.confidence,
                    accepted: false,
                    rejectionReason: "Too close to a stronger impact"
                ))
            } else {
                finalCandidates.append(c)
            }
        }

        return ImpactDetectionResult(
            impactTimestamps: acceptedTimes.sorted(),
            candidates: finalCandidates
        )
    }

    // MARK: - Pass 1: build the per-window peak envelope.

    /// Decodes the entire audio track and returns one AudioPeak per ~23 ms window.
    /// Includes ALL windows (no amplitude floor) because the noise-floor
    /// estimator needs the quiet stretches too.
    private func readPeakEnvelope(for video: ImportedVideo,
                                  progress: @escaping (Double) -> Void) async throws -> [AudioPeak] {
        let asset = AVURLAsset(url: video.localFileURL)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioImpactError.noAudioTrack
        }

        let totalDuration = video.duration

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioImpactError.readerFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: analysisSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
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

        var peaks: [AudioPeak] = []
        peaks.reserveCapacity(Int(totalDuration / windowDuration) + 16)
        var currentWindow: [Float] = []
        currentWindow.reserveCapacity(windowSampleCount)
        var samplesProcessed: Int64 = 0
        var lastReportedProgress: Double = -1

        while reader.status == .reading,
              let sampleBuffer = trackOutput.copyNextSampleBuffer() {

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            let totalLength = CMBlockBufferGetDataLength(blockBuffer)

            var bytes = [UInt8](repeating: 0, count: totalLength)
            let copyStatus = bytes.withUnsafeMutableBytes { rawBuf -> OSStatus in
                guard let base = rawBuf.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(blockBuffer,
                                                  atOffset: 0,
                                                  dataLength: totalLength,
                                                  destination: base)
            }
            CMSampleBufferInvalidate(sampleBuffer)
            guard copyStatus == kCMBlockBufferNoErr else { continue }

            let sampleCount = totalLength / MemoryLayout<Float>.size
            let floats: [Float] = bytes.withUnsafeBytes { raw -> [Float] in
                let buf = raw.bindMemory(to: Float.self)
                return Array(UnsafeBufferPointer(start: buf.baseAddress, count: sampleCount))
            }

            for sample in floats {
                currentWindow.append(sample)
                if currentWindow.count >= windowSampleCount {
                    var peak: Float = 0
                    for s in currentWindow {
                        let v = abs(s)
                        if v > peak { peak = v }
                    }
                    let timeSec = Double(samplesProcessed) / analysisSampleRate
                    peaks.append(AudioPeak(time: timeSec, amplitude: Double(peak)))
                    samplesProcessed += Int64(windowSampleCount)
                    currentWindow.removeAll(keepingCapacity: true)
                }
            }

            // Throttle progress to ~100 updates so we don't flood MainActor.
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
        return peaks
    }
}
