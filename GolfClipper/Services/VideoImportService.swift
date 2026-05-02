// VideoImportService.swift
// Handles copying a user-picked video out of Photos and into our app's
// Documents directory so we can read its audio and export clips.
//
// We use PhotosUI's PhotosPickerItem (iOS 16+) which gives us a Transferable
// we can load as a file URL. We then copy the file into our videos folder.

import Foundation
import PhotosUI
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

enum VideoImportError: LocalizedError {
    case loadFailed
    case copyFailed
    case unsupportedItem
    case noDuration

    var errorDescription: String? {
        switch self {
        case .loadFailed:     return "Could not load the selected video."
        case .copyFailed:     return "Could not copy the video into the app."
        case .unsupportedItem:return "That item is not a supported video."
        case .noDuration:     return "Could not read the video's duration."
        }
    }
}

final class VideoImportService {

    /// Imports a video from a PhotosPickerItem.
    /// - Returns: An ImportedVideo whose file is now stored in Documents.
    func importVideo(from item: PhotosPickerItem) async throws -> ImportedVideo {
        // 1. Get a temporary URL for the picked item.
        guard let tempURL = try await loadVideoURL(from: item) else {
            throw VideoImportError.unsupportedItem
        }

        // 2. Copy that file into our own Documents/ImportedVideos folder.
        //    PhotosUI's URL is in a temp sandbox and may disappear.
        let videosFolder = FileManagerHelpers.videosFolderURL
        let originalName = tempURL.lastPathComponent
        let safeName = "\(UUID().uuidString)_\(originalName)"
        let destURL = videosFolder.appendingPathComponent(safeName)

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: destURL)
        } catch {
            throw VideoImportError.copyFailed
        }

        // 3. Read duration with AVFoundation.
        let asset = AVURLAsset(url: destURL)
        let duration: Double
        do {
            let cm = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cm)
        } catch {
            throw VideoImportError.noDuration
        }
        guard duration.isFinite, duration > 0 else {
            throw VideoImportError.noDuration
        }

        // 4. Build and return the model. We persist a relative path so the
        //    record survives sandbox path changes.
        let relPath = FileManagerHelpers.relativePath(for: destURL)
        return ImportedVideo(
            originalFilename: originalName,
            relativePath: relPath,
            importedAt: Date(),
            duration: duration
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

    // MARK: - Private

    /// Use Transferable to get a file URL for the picked item.
    /// We use a small wrapper so we control where the temp file lives.
    private func loadVideoURL(from item: PhotosPickerItem) async throws -> URL? {
        do {
            let movie: VideoFile? = try await item.loadTransferable(type: VideoFile.self)
            return movie?.url
        } catch {
            throw VideoImportError.loadFailed
        }
    }
}

/// Transferable wrapper that copies the imported video to a temp file we own.
/// Required because PhotosPickerItem.loadTransferable(type: URL.self) returns
/// a URL that can disappear before we use it.
struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { videoFile in
            SentTransferredFile(videoFile.url)
        } importing: { received in
            // Copy received.file into a temp directory that we control.
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent("import_\(UUID().uuidString).mov")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return VideoFile(url: tempURL)
        }
    }
}
