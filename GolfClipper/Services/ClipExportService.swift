// ClipExportService.swift
// Cuts the imported video into individual swing clips around impact times.
//
// V3 — preset-fallback chain to dodge the ProRes hardware path:
//
//   1. Try AVAssetExportPresetPassthrough first. Passthrough copies the
//      source's video/audio streams without re-encoding, so iPhones
//      without ProRes encoder hardware can still process ProRes-source
//      video (recorded by iPhone 13 Pro+). It's also the fastest path.
//   2. If passthrough refuses (some sources can't be cleanly trimmed
//      without re-encoding), fall back to AVAssetExportPresetMediumQuality
//      which forces H.264. Slightly lower quality but universally supported.
//   3. If both fail, surface the error so the batch reports it.
//
// Each clip exports SEQUENTIALLY (the for-loop in `exportClips` awaits
// each `exportClip` before starting the next) — running 33 simultaneous
// export sessions would crater the device. The progress callback lets
// the UI show "Creating clip N of M…" while it grinds through.
//
// Diagnostic logging is verbose on purpose during the V3 bring-up;
// strip the [NiceShot] lines once long-video export is stable.

import Foundation
import AVFoundation

enum ClipExportError: LocalizedError {
    case sessionCreationFailed
    case exportFailed(String)
    case invalidTimeRange

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed: return "Could not create the clip export session."
        case .exportFailed(let why): return "Clip export failed: \(why)"
        case .invalidTimeRange:      return "Clip start/end times are invalid."
        }
    }
}

final class ClipExportService {

    /// Preset chain — tried in order until one succeeds.
    private static let presetChain: [String] = [
        AVAssetExportPresetPassthrough,
        AVAssetExportPresetMediumQuality
    ]

    /// Export ONE clip around a single impact timestamp.
    func exportClip(from video: ImportedVideo,
                    impactTime: Double,
                    settings: DetectionSettings,
                    isManual: Bool) async throws -> SwingClip {

        let start = max(0, impactTime - settings.preImpactSeconds)
        let end   = min(video.duration, impactTime + settings.postImpactSeconds)
        guard end > start else { throw ClipExportError.invalidTimeRange }

        print(String(format:
            "[NiceShot] Export clip impact=%.2fs start=%.2fs end=%.2fs duration=%.2fs",
            impactTime, start, end, end - start))

        let asset = AVURLAsset(url: video.localFileURL)
        let clipId = UUID()
        let outputURL = FileManagerHelpers.clipsFolderURL
            .appendingPathComponent("clip_\(clipId.uuidString).mov")

        var lastError: Error?
        for preset in Self.presetChain {
            // Make sure we don't accidentally collide with a leftover file
            // from a previous attempt of this same clip.
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }

            print("[NiceShot]   Trying preset: \(preset)")

            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                print("[NiceShot]   ✗ Could not create AVAssetExportSession with \(preset)")
                lastError = ClipExportError.sessionCreationFailed
                continue
            }

            session.outputURL = outputURL
            session.outputFileType = .mov
            session.shouldOptimizeForNetworkUse = true
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end:   CMTime(seconds: end,   preferredTimescale: 600)
            )

            // iOS 17-compatible callback API wrapped in a continuation.
            // (`session.export() async` only exists on iOS 18+.)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    cont.resume()
                }
            }

            switch session.status {
            case .completed:
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
                print("[NiceShot]   ✓ Export OK (\(preset)): \(fileSize) bytes")
                let clip = SwingClip(
                    id: clipId,
                    sourceVideoId: video.id,
                    relativePath: FileManagerHelpers.relativePath(for: outputURL),
                    createdAt: Date(),
                    duration: end - start,
                    impactTimestamp: impactTime,
                    startTime: start,
                    endTime: end,
                    isManual: isManual,
                    isSavedToPhotos: false
                )
                return clip

            case .failed, .cancelled:
                let nsError = session.error as NSError?
                let domain = nsError?.domain ?? "?"
                let code = nsError?.code ?? 0
                let desc = session.error?.localizedDescription ?? "unknown"
                print("[NiceShot]   ✗ Export FAILED (\(preset)): [\(domain) \(code)] \(desc)")
                if let underlying = nsError?.userInfo[NSUnderlyingErrorKey] {
                    print("[NiceShot]     underlying: \(underlying)")
                }
                lastError = session.error ?? ClipExportError.exportFailed(desc)
                continue

            default:
                let desc = "status \(session.status.rawValue)"
                print("[NiceShot]   ✗ Export ended in unexpected state (\(preset)): \(desc)")
                lastError = ClipExportError.exportFailed(desc)
                continue
            }
        }

        // All presets failed.
        throw ClipExportError.exportFailed(lastError?.localizedDescription ?? "all presets failed")
    }

    /// Export MANY clips, one per impact timestamp, sequentially.
    /// Reports progress as `(completedCount, totalCount)` after each clip.
    func exportClips(from video: ImportedVideo,
                     impactTimes: [Double],
                     settings: DetectionSettings,
                     isManual: Bool = false,
                     progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> [SwingClip] {

        let total = impactTimes.count
        print("[NiceShot] Beginning clip export: \(total) clips for \(video.originalFilename)")

        var results: [SwingClip] = []
        results.reserveCapacity(total)

        for (idx, t) in impactTimes.enumerated() {
            // Update UI before kicking off the next clip so the user
            // sees "Creating clip N of M…" while it actually runs.
            progress(idx, total)
            print("[NiceShot] Clip \(idx + 1)/\(total) — impact at \(String(format: "%.2f", t))s")
            do {
                let clip = try await exportClip(from: video,
                                                impactTime: t,
                                                settings: settings,
                                                isManual: isManual)
                results.append(clip)
            } catch {
                print("[NiceShot] Clip \(idx + 1)/\(total) FAILED: \(error.localizedDescription)")
            }
        }

        // Final progress tick so the bar fills to total/total.
        progress(total, total)

        let succeeded = results.count
        let failed = total - succeeded
        print("[NiceShot] Clip export complete: \(succeeded)/\(total) succeeded, \(failed) failed")

        return results
    }
}
