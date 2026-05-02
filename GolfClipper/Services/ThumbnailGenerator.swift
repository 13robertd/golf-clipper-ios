// ThumbnailGenerator.swift
// Generates a single JPEG thumbnail for a clip using AVAssetImageGenerator.
// Stored in Documents/Thumbnails so the clip review list can show previews
// without re-decoding the video each time.

import Foundation
import AVFoundation
import UIKit

final class ThumbnailGenerator {

    /// Generate a thumbnail for the given clip.
    /// We grab a frame near the impact moment so the preview shows
    /// roughly when ball-meet-club happens.
    @discardableResult
    func generateThumbnail(for clip: SwingClip) async -> URL? {
        let asset = AVURLAsset(url: clip.localFileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)

        // Aim for the impact moment relative to the clip start.
        let impactInClip = clip.impactTimestamp - clip.startTime
        let safeTime = max(0, min(impactInClip, clip.duration - 0.1))
        let cmTime = CMTime(seconds: safeTime, preferredTimescale: 600)

        do {
            let image = try await imageAsync(generator: generator, at: cmTime)
            let url = FileManagerHelpers.thumbnailsFolderURL
                .appendingPathComponent("thumb_\(clip.id.uuidString).jpg")
            if let data = image.jpegData(compressionQuality: 0.8) {
                try data.write(to: url, options: .atomic)
                return url
            }
        } catch {
            print("ThumbnailGenerator: failed for clip \(clip.id): \(error)")
        }
        return nil
    }

    /// Async wrapper around the older callback-style image API so we get a
    /// single UIImage out without needing iOS 18.
    private func imageAsync(generator: AVAssetImageGenerator,
                            at time: CMTime) async throws -> UIImage {
        try await withCheckedThrowingContinuation { cont in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, error in
                switch result {
                case .succeeded:
                    if let cgImage {
                        cont.resume(returning: UIImage(cgImage: cgImage))
                    } else {
                        cont.resume(throwing: NSError(domain: "Thumb", code: 1))
                    }
                case .failed, .cancelled:
                    cont.resume(throwing: error ?? NSError(domain: "Thumb", code: 2))
                @unknown default:
                    cont.resume(throwing: NSError(domain: "Thumb", code: 3))
                }
            }
        }
    }
}
