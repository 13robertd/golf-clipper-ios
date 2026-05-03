// VideoImportService.swift
// Copies a user-picked video from the Photos library into our app's
// Documents directory so the rest of the pipeline can read it.
//
// V2 — replaces the PhotosPicker / PhotosPickerItem path. We now go
// directly through the Photos framework using a PHAsset local
// identifier. `PHAssetResourceManager.writeData` streams the original
// video file to a destination URL we control. iCloud-only assets are
// downloaded automatically (`isNetworkAccessAllowed = true`).

import Foundation
import AVFoundation
import Photos

enum VideoImportError: LocalizedError {
    case loadFailed
    case copyFailed(String)
    case unsupportedItem
    case noDuration

    var errorDescription: String? {
        switch self {
        case .loadFailed:           return "Could not load the selected video."
        case .copyFailed(let why):  return "Could not copy the video: \(why)."
        case .unsupportedItem:      return "That item is not a supported video."
        case .noDuration:           return "Could not read the video's duration."
        }
    }
}

final class VideoImportService {

    /// Imports a video by Photos asset local identifier.
    /// - Returns: an ImportedVideo whose file lives in Documents.
    func importVideo(fromAssetIdentifier identifier: String) async throws -> ImportedVideo {
        // 1. Locate the PHAsset.
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else {
            throw VideoImportError.unsupportedItem
        }

        // 2. Find the video resource. (One PHAsset can have multiple
        //    resources — full video, paired image, slow-mo metadata —
        //    and we want the canonical .video one.)
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first
        else {
            throw VideoImportError.unsupportedItem
        }

        // 3. Build a destination URL inside Documents/ImportedVideos.
        let videosFolder = FileManagerHelpers.videosFolderURL
        let originalName = videoResource.originalFilename
        let safeName = "\(UUID().uuidString)_\(originalName)"
        let destURL = videosFolder.appendingPathComponent(safeName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        // 4. Copy the original video data. iCloud Photos may need to
        //    download first — that's why isNetworkAccessAllowed=true.
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true

        do {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: videoResource,
                    toFile: destURL,
                    options: opts
                ) { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        } catch {
            throw VideoImportError.copyFailed(error.localizedDescription)
        }

        // 5. Read duration via AVFoundation.
        let avAsset = AVURLAsset(url: destURL)
        let duration: Double
        do {
            let cm = try await avAsset.load(.duration)
            duration = CMTimeGetSeconds(cm)
        } catch {
            throw VideoImportError.noDuration
        }
        guard duration.isFinite, duration > 0 else {
            throw VideoImportError.noDuration
        }

        // 6. File size on disk (motivates the cleanup banner).
        let fileSizeBytes: Int64? = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
                  let n = attrs[.size] as? NSNumber else { return nil }
            return n.int64Value
        }()

        // 7. Build the model. Asset identifier is preserved so the
        //    cleanup banner can later offer to delete the original.
        let relPath = FileManagerHelpers.relativePath(for: destURL)
        return ImportedVideo(
            originalFilename: originalName,
            relativePath: relPath,
            importedAt: Date(),
            duration: duration,
            originalAssetIdentifier: identifier,
            fileSizeBytes: fileSizeBytes
        )
    }

    /// Best-effort: returns true if the asset has at least one audio track.
    func videoHasAudioTrack(_ video: ImportedVideo) async -> Bool {
        let asset = AVURLAsset(url: video.localFileURL)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            return !tracks.isEmpty
        } catch {
            return false
        }
    }
}
