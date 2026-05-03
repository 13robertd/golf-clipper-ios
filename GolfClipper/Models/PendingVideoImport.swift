// PendingVideoImport.swift
//
// Lightweight pre-import record used by the Review Selected Videos
// screen. The user picks videos in CustomVideoBrowserView (V2) but
// the app does NOT copy any file into Documents until the user taps
// "Start Clipping". The pending entry holds enough metadata to render
// a card (filename / duration / thumbnail) plus the Photos asset
// localIdentifier so the surviving entries can be handed to the
// existing AppState import pipeline untouched.

import Foundation
import SwiftUI
import Photos

struct PendingVideoImport: Identifiable {
    let id: UUID
    /// PHAsset.localIdentifier — required for both processing and the
    /// "Delete from Photos" action on the review screen.
    let assetIdentifier: String
    var originalFilename: String?
    var duration: TimeInterval?
    var thumbnail: UIImage?
    /// Last delete-original error, if any. nil = no attempt or success.
    var deletionErrorMessage: String?

    init(id: UUID = UUID(),
         assetIdentifier: String,
         originalFilename: String? = nil,
         duration: TimeInterval? = nil,
         thumbnail: UIImage? = nil,
         deletionErrorMessage: String? = nil) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.originalFilename = originalFilename
        self.duration = duration
        self.thumbnail = thumbnail
        self.deletionErrorMessage = deletionErrorMessage
    }
}

// Identity-based equality. UIImage is not Equatable, so we can't get
// a synthesized impl — but identity is all we need (entries are
// mutated in place; lookups are by id).
extension PendingVideoImport: Equatable {
    static func == (lhs: PendingVideoImport, rhs: PendingVideoImport) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Building from selected asset identifiers

extension PendingVideoImport {

    /// Build a list of PendingVideoImport from selected Photos asset
    /// local identifiers. Fetches metadata in parallel via PHAsset and
    /// preserves the input order. No files are copied at this stage.
    ///
    /// .readWrite access is needed to read PHAsset metadata; we ask
    /// once silently if undetermined. If denied, fields fall back to
    /// nil and the review screen renders placeholder cards — Remove
    /// from Queue still works, and Delete Original re-requests on
    /// its own (PhotosDeleteService handles that).
    static func build(fromAssetIdentifiers ids: [String]) async -> [PendingVideoImport] {
        _ = await ensureReadAccess()

        return await withTaskGroup(of: (Int, PendingVideoImport).self) { group in
            for (idx, id) in ids.enumerated() {
                group.addTask {
                    let pending = await PendingVideoImport.fromAssetIdentifier(id)
                    return (idx, pending)
                }
            }
            var indexed: [(Int, PendingVideoImport)] = []
            for await pair in group {
                indexed.append(pair)
            }
            indexed.sort { $0.0 < $1.0 }
            return indexed.map { $0.1 }
        }
    }

    private static func fromAssetIdentifier(_ id: String) async -> PendingVideoImport {
        var pending = PendingVideoImport(assetIdentifier: id)
        let metadata = await fetchPHAssetMetadata(forAssetID: id)
        pending.originalFilename = metadata.filename
        pending.duration = metadata.duration
        pending.thumbnail = metadata.thumbnail
        return pending
    }

    private static func fetchPHAssetMetadata(forAssetID id: String)
        async -> (filename: String?, duration: TimeInterval?, thumbnail: UIImage?) {

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else {
            return (nil, nil, nil)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let filename = resources.first?.originalFilename
        let duration = asset.duration

        let thumbnail = await loadThumbnail(for: asset)
        return (filename, duration, thumbnail)
    }

    private static func loadThumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            // .fastFormat → exactly one callback with a quick-to-load
            // image. Avoids the multi-callback dance of .opportunistic.
            opts.deliveryMode = .fastFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 240, height: 180),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    /// Best-effort .readWrite request. Returns true if we have any
    /// kind of read access (full or limited). Never throws; if the
    /// user declines we just lose metadata, not the whole flow.
    private static func ensureReadAccess() async -> Bool {
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
}
