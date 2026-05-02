// PhotosSaveService.swift
// Saves an exported clip file back to the user's iPhone Photos library.
// Uses the Photos framework. Requires NSPhotoLibraryAddUsageDescription
// (and optionally NSPhotoLibraryUsageDescription) in Info.plist.

import Foundation
import Photos

enum PhotosSaveError: LocalizedError {
    case permissionDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Photos access was denied. Enable it in Settings → Privacy → Photos."
        case .saveFailed(let why):
            return "Could not save clip to Photos: \(why)"
        }
    }
}

final class PhotosSaveService {

    /// Request "add only" permission, returning true on success.
    func requestAddPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    cont.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            return false
        }
    }

    /// Save a single video file URL into Photos.
    func saveVideoToPhotos(at fileURL: URL) async throws {
        guard await requestAddPermission() else {
            throw PhotosSaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }, completionHandler: { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: PhotosSaveError.saveFailed(error?.localizedDescription ?? "unknown"))
                }
            })
        }
    }
}
