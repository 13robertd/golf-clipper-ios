// PhotosLibraryManager.swift
//
// V2 — replaces SwiftUI's PhotosPicker. Centralises Photos framework
// access so the custom video browser can:
//   • check / request .readWrite authorization
//   • fetch all videos (mediaType == .video) sorted newest-first
//   • render thumbnails through a single PHCachingImageManager so
//     scrolling stays smooth at 60fps
//   • prefetch a window of thumbnails ahead of the viewport
//
// All published state mutates on the main actor — views can observe
// directly without dispatch hopping.

import Foundation
import Photos
import UIKit
import SwiftUI

@MainActor
final class PhotosLibraryManager: ObservableObject {

    /// Latest snapshot of the user's Photos authorization (read-write
    /// scope). Drives which view the browser presents.
    @Published var authStatus: PHAuthorizationStatus

    /// Videos available to the app, sorted newest creation date first.
    /// Empty until `fetchVideos()` runs.
    @Published private(set) var assets: [PHAsset] = []

    /// Pixel size used for every thumbnail request. The browser sets
    /// this once when the grid lays out (cell width × screen scale).
    var thumbnailTargetSize: CGSize = CGSize(width: 400, height: 400)

    private let imageManager = PHCachingImageManager()

    // MARK: - Lifecycle

    init() {
        self.authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    deinit {
        imageManager.stopCachingImagesForAllAssets()
    }

    // MARK: - Authorization

    /// Request .readWrite if not yet determined; no-op otherwise.
    /// Returns the resulting status so callers can branch.
    @discardableResult
    func requestAuthorization() async -> PHAuthorizationStatus {
        if authStatus != .notDetermined { return authStatus }
        let newStatus = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
        self.authStatus = newStatus
        return newStatus
    }

    /// Re-read the current status (e.g. when the app comes back from
    /// Settings.app). The browser calls this on `.foreground`.
    func refreshAuthStatus() {
        self.authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - Fetching videos

    /// Synchronous PHFetch with the app's predicate. Cheap — Photos
    /// framework only returns lightweight asset references here, no
    /// pixels are loaded.
    func fetchVideos() {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var arr: [PHAsset] = []
        arr.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            arr.append(asset)
        }
        self.assets = arr
    }

    /// Drop one asset from the in-memory list. Called after the user
    /// deletes the original via the Phase 2 context menu so the grid
    /// reflects the change without a full refetch. Wrap the call in
    /// `withAnimation` if you want a fade-out transition.
    func removeAsset(withIdentifier id: String) {
        assets.removeAll { $0.localIdentifier == id }
    }

    /// Toggle the Photos "favorite" star for one asset via
    /// PHAssetChangeRequest. Throws if Photos refuses the change
    /// (permission, system error). The local PHAsset reference does
    /// not auto-refresh — the next long-press can show stale state
    /// until the next fetchVideos(). Acceptable for V1.
    func toggleFavorite(for asset: PHAsset) async throws {
        let newValue = !asset.isFavorite
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetChangeRequest(for: asset)
                req.isFavorite = newValue
            } completionHandler: { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: error
                                ?? NSError(domain: "PhotosLibraryManager",
                                           code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: "Couldn't update favorite"]))
                }
            }
        }
    }

    // MARK: - Thumbnails

    /// Request a thumbnail for one asset. Returns the request id so
    /// the cell can cancel if it scrolls off-screen.
    @discardableResult
    func requestThumbnail(for asset: PHAsset,
                          completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let opts = thumbRequestOptions()
        return imageManager.requestImage(
            for: asset,
            targetSize: thumbnailTargetSize,
            contentMode: .aspectFill,
            options: opts
        ) { image, _ in
            // requestImage may call back on a background queue.
            // Hop to main so SwiftUI state mutations stay safe.
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func cancelImageRequest(_ id: PHImageRequestID) {
        guard id != PHInvalidImageRequestID else { return }
        imageManager.cancelImageRequest(id)
    }

    // MARK: - Prefetch caching

    /// Begin caching thumbnails for a window of assets. The browser
    /// calls this once with the first ~60 assets to warm the cache;
    /// after that PHCachingImageManager handles per-request caching.
    func startCaching(for windowAssets: [PHAsset]) {
        guard !windowAssets.isEmpty else { return }
        imageManager.startCachingImages(
            for: windowAssets,
            targetSize: thumbnailTargetSize,
            contentMode: .aspectFill,
            options: thumbRequestOptions()
        )
    }

    func stopCaching(for windowAssets: [PHAsset]) {
        guard !windowAssets.isEmpty else { return }
        imageManager.stopCachingImages(
            for: windowAssets,
            targetSize: thumbnailTargetSize,
            contentMode: .aspectFill,
            options: thumbRequestOptions()
        )
    }

    func stopAllCaching() {
        imageManager.stopCachingImagesForAllAssets()
    }

    // MARK: - Helpers

    private func thumbRequestOptions() -> PHImageRequestOptions {
        let opts = PHImageRequestOptions()
        // .opportunistic is the right mode for a scrolling grid: a
        // low-res placeholder arrives almost immediately, replaced by
        // the high-quality image when it's ready. The cell handles
        // the multi-callback case by just overwriting `image`.
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        // CRITICAL for scroll perf: do NOT block on iCloud downloads
        // for thumbnails. iCloud-only assets show the dark placeholder
        // until they're locally cached. The actual import path
        // (VideoImportService) DOES allow network — it has to.
        opts.isNetworkAccessAllowed = false
        opts.isSynchronous = false
        return opts
    }
}
