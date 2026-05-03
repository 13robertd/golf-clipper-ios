// PhotosDeleteService.swift
// Deletes original source videos from the user's Photos library after
// their clips have been safely saved.
//
// Important details:
//
//  • Deletion requires `.readWrite` Photos authorization. `.addOnly`
//    (which we use for saving clips) is NOT enough. We escalate to
//    .readWrite the first time deletion is attempted.
//
//  • `PHPhotoLibrary.performChanges` with `PHAssetChangeRequest.deleteAssets`
//    pops Apple's own confirmation dialog. We rely on that as the final
//    user safeguard — the app never adds a second custom confirmation.
//
//  • Batching: we pass every asset identifier into a SINGLE
//    `performChanges` call so the user sees one system dialog rather
//    than one per video.
//
//  • If the user cancels Apple's system dialog, we return
//    `.userCancelled` for every requested id. The caller should treat
//    that as "Keep Originals" — silently, no error.

import Foundation
import Photos

/// Per-asset outcome of a deletion attempt.
enum PhotosDeleteOutcome: Equatable {
    case deleted
    case notFound          // asset id doesn't match anything in the library
    case userCancelled     // user tapped "Don't Allow" / "Cancel" in Apple's system dialog
    case failed(String)    // anything else — message is suitable to show the user
}

struct PhotosDeleteResult: Equatable {
    let assetIdentifier: String
    let outcome: PhotosDeleteOutcome

    var success: Bool {
        if case .deleted = outcome { return true }
        return false
    }
}

enum PhotosDeleteError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Photos access is needed to delete originals. Enable it in Settings → Privacy → Photos."
        }
    }
}

final class PhotosDeleteService {

    /// Request the read-write Photos authorization required for deletion.
    /// Returns true on `.authorized` or `.limited` (limited works, but only
    /// for assets the user included in their limited selection).
    func requestDeletePermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    cont.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            return false
        }
    }

    /// Delete a single asset by its `PHAsset.localIdentifier`.
    /// Throws `PhotosDeleteError.permissionDenied` if read-write access
    /// is refused. Other failure modes (not found, user-cancelled, system
    /// error) are returned as a non-throwing `PhotosDeleteResult`.
    func deleteOriginal(assetIdentifier: String) async throws -> PhotosDeleteResult {
        let results = try await deleteOriginals(assetIdentifiers: [assetIdentifier])
        return results.first ?? PhotosDeleteResult(assetIdentifier: assetIdentifier,
                                                   outcome: .failed("Unknown"))
    }

    /// Delete many assets in a single `performChanges` call so the user
    /// sees one system confirmation dialog. Returns one result per input
    /// identifier, in input order.
    ///
    /// Throws only when the user has explicitly denied Photos access. All
    /// other failure modes (asset missing, system rejected the change,
    /// user cancelled the system dialog) are surfaced as per-asset results.
    func deleteOriginals(assetIdentifiers: [String]) async throws -> [PhotosDeleteResult] {
        guard !assetIdentifiers.isEmpty else { return [] }

        guard await requestDeletePermission() else {
            throw PhotosDeleteError.permissionDenied
        }

        // Find which ids actually map to live PHAssets right now. Anything
        // missing was probably already removed in Photos (manual delete,
        // moved to another library, etc.).
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: nil)
        var found: [String: PHAsset] = [:]
        fetch.enumerateObjects { asset, _, _ in
            found[asset.localIdentifier] = asset
        }

        // Nothing to delete (every requested asset is gone). Skip Apple's
        // dialog entirely and return notFound for each.
        if found.isEmpty {
            return assetIdentifiers.map {
                PhotosDeleteResult(assetIdentifier: $0, outcome: .notFound)
            }
        }

        // Run a single performChanges batch. Apple's system confirmation
        // appears here.
        let outcome: (success: Bool, error: Error?) = await withCheckedContinuation {
            (cont: CheckedContinuation<(Bool, Error?), Never>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(fetch as NSFastEnumeration)
            }, completionHandler: { success, error in
                cont.resume(returning: (success, error))
            })
        }

        // Build the per-asset result table.
        return assetIdentifiers.map { id in
            // Wasn't in the library at all → notFound regardless of dialog outcome.
            guard found[id] != nil else {
                return PhotosDeleteResult(assetIdentifier: id, outcome: .notFound)
            }
            if outcome.success {
                return PhotosDeleteResult(assetIdentifier: id, outcome: .deleted)
            }
            // performChanges returns `success = false` when the user taps
            // Cancel in Apple's system dialog. Detect that and emit
            // .userCancelled so the caller can treat it silently.
            if let err = outcome.error as? PHPhotosError, err.code == .userCancelled {
                return PhotosDeleteResult(assetIdentifier: id, outcome: .userCancelled)
            }
            if outcome.error == nil {
                // No error and not success — this is also user cancellation
                // on some iOS versions. Treat the same.
                return PhotosDeleteResult(assetIdentifier: id, outcome: .userCancelled)
            }
            return PhotosDeleteResult(
                assetIdentifier: id,
                outcome: .failed(outcome.error?.localizedDescription ?? "unknown")
            )
        }
    }
}
