// ClipExportService.swift
// Cuts the imported video into individual swing clips around impact times.
//
// We use AVAssetExportSession with AVAssetExportPresetHighestQuality for
// reasonable visual quality without re-encoding complexity. The output is
// a .mov file in Documents/Clips.
//
// For each impact timestamp:
//   startTime = max(0, impact - preImpactSeconds)
//   endTime   = min(videoDuration, impact + postImpactSeconds)

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

    /// Export ONE clip around a single impact timestamp.
    func exportClip(from video: ImportedVideo,
                    impactTime: Double,
                    settings: DetectionSettings,
                    isManual: Bool) async throws -> SwingClip {

        let start = max(0, impactTime - settings.preImpactSeconds)
        let end   = min(video.duration, impactTime + settings.postImpactSeconds)
        guard end > start else { throw ClipExportError.invalidTimeRange }

        let asset = AVURLAsset(url: video.localFileURL)

        // Build export session.
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ClipExportError.sessionCreationFailed
        }

        let clipId = UUID()
        let outputURL = FileManagerHelpers.clipsFolderURL
            .appendingPathComponent("clip_\(clipId.uuidString).mov")

        // Ensure no leftover file at that path.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        session.outputURL = outputURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true

        // Convert seconds to CMTime. 600 is a common timescale for video.
        let startCM = CMTime(seconds: start, preferredTimescale: 600)
        let endCM   = CMTime(seconds: end,   preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: startCM, end: endCM)

        // Run export. We use the iOS 17-compatible callback API wrapped in a
        // continuation. (`session.export() async` only exists on iOS 18+.)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                cont.resume()
            }
        }

        switch session.status {
        case .completed:
            let duration = end - start
            let clip = SwingClip(
                id: clipId,
                sourceVideoId: video.id,
                relativePath: FileManagerHelpers.relativePath(for: outputURL),
                createdAt: Date(),
                duration: duration,
                impactTimestamp: impactTime,
                startTime: start,
                endTime: end,
                isManual: isManual,
                isSavedToPhotos: false
            )
            return clip
        case .failed, .cancelled:
            throw ClipExportError.exportFailed(session.error?.localizedDescription ?? "unknown")
        default:
            throw ClipExportError.exportFailed("status \(session.status.rawValue)")
        }
    }

    /// Export MANY clips, one per impact timestamp.
    /// Reports progress as `(completedCount, totalCount)`.
    func exportClips(from video: ImportedVideo,
                     impactTimes: [Double],
                     settings: DetectionSettings,
                     isManual: Bool = false,
                     progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> [SwingClip] {
        var results: [SwingClip] = []
        let total = impactTimes.count
        for (idx, t) in impactTimes.enumerated() {
            do {
                let clip = try await exportClip(from: video,
                                                impactTime: t,
                                                settings: settings,
                                                isManual: isManual)
                results.append(clip)
            } catch {
                // Skip failed clips but keep going so one failure doesn't kill all.
                print("ClipExportService: failed to export clip at \(t)s: \(error)")
            }
            progress(idx + 1, total)
        }
        return results
    }
}
