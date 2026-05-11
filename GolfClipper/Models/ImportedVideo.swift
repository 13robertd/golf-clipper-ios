// ImportedVideo.swift
// Represents a video the user imported from their Photos library.
// We persist this to local JSON so the app can remember it across launches.
//
// V1.5 (multi-video / batch import):
//  - Added optional `batchId` so we can group videos imported together.
//  - Added `processingStatus` so the home screen can show per-video state
//    (pending / analyzing / done / failed / no audio / no shots).
//  - Added `errorMessage` for the failure cases.

import Foundation

/// Per-video state in the batch pipeline.
enum VideoProcessingStatus: String, Codable, CaseIterable, Hashable {
    case pending           // queued, waiting for the batch to reach it
    case importing         // copying file out of Photos
    case analyzing         // reading + decoding audio
    case detectingShots    // running impact detection
    case validatingMotion  // V3.5 — frame-diff filter on audio candidates
    case creatingClips     // exporting individual clip files
    case completed         // finished, has at least one clip
    case noAudio           // video has no audio track — manual-clip only
    case noShotsFound      // analysis ran cleanly but produced zero impacts
    case failed            // import or processing error (see errorMessage)

    /// Short label suitable for status badges and the batch progress view.
    var displayName: String {
        switch self {
        case .pending:           return "Waiting"
        case .importing:         return "Importing video"
        case .analyzing:         return "Analyzing audio"
        case .detectingShots:    return "Detecting shots"
        case .validatingMotion:  return "Validating swings"
        case .creatingClips:     return "Creating clips"
        case .completed:         return "Done"
        case .noAudio:           return "No audio"
        case .noShotsFound:      return "No shots found"
        case .failed:            return "Failed"
        }
    }

    /// True once a video reaches an end state (success or skip or failure).
    var isTerminal: Bool {
        switch self {
        case .completed, .noAudio, .noShotsFound, .failed: return true
        default: return false
        }
    }
}

struct ImportedVideo: Identifiable, Codable, Hashable {
    let id: UUID
    var originalFilename: String
    /// Stored relative to Documents so the record survives sandbox path
    /// changes between launches.
    var relativePath: String
    var importedAt: Date
    var duration: Double // seconds

    // V1.5 batch fields (optional / defaulted for backward-compat).
    var batchId: UUID?
    var processingStatus: VideoProcessingStatus
    var errorMessage: String?

    // V1.6 — original-from-Photos cleanup.
    /// PHAsset.localIdentifier captured at import time. Required to delete
    /// the original from the user's Photos library later. May be nil if
    /// the imported item didn't come from a Photos asset (rare; e.g. a
    /// share extension or some external picker we don't currently use).
    var originalAssetIdentifier: String?
    /// Set to true once we've successfully deleted the source video from
    /// the Photos library. Persists across launches so the row badge stays.
    var wasOriginalDeletedFromPhotos: Bool
    /// Last deletion attempt's error message (for surfacing in the UI).
    /// nil after a successful delete; nil if we've never tried.
    var deletionErrorMessage: String?

    // V1.7 — cleanup banner motivator.
    /// Size of the imported video file in bytes. Captured at import time
    /// and shown in the cleanup banner ("free up 248 MB"). Optional so
    /// records persisted before V1.7 still load — AppState backfills any
    /// missing sizes from disk on launch.
    var fileSizeBytes: Int64?

    // V4.1 — detection-mode persistence.
    /// Which DetectionMode tuning bundle was used to produce this video's
    /// current clips. Written by `AppState.processVideo` on the first run
    /// (auto-detected from duration) and overwritten by the chip's tap
    /// action. Optional so legacy records (pre-V4.1) load with nil and
    /// pick up an auto-detected mode on next processing pass.
    var detectionMode: DetectionMode?

    var localFileURL: URL {
        FileManagerHelpers.documentsDirectory.appendingPathComponent(relativePath)
    }

    init(id: UUID = UUID(),
         originalFilename: String,
         relativePath: String,
         importedAt: Date = Date(),
         duration: Double,
         batchId: UUID? = nil,
         processingStatus: VideoProcessingStatus = .pending,
         errorMessage: String? = nil,
         originalAssetIdentifier: String? = nil,
         wasOriginalDeletedFromPhotos: Bool = false,
         deletionErrorMessage: String? = nil,
         fileSizeBytes: Int64? = nil,
         detectionMode: DetectionMode? = nil) {
        self.id = id
        self.originalFilename = originalFilename
        self.relativePath = relativePath
        self.importedAt = importedAt
        self.duration = duration
        self.batchId = batchId
        self.processingStatus = processingStatus
        self.errorMessage = errorMessage
        self.originalAssetIdentifier = originalAssetIdentifier
        self.wasOriginalDeletedFromPhotos = wasOriginalDeletedFromPhotos
        self.deletionErrorMessage = deletionErrorMessage
        self.fileSizeBytes = fileSizeBytes
        self.detectionMode = detectionMode
    }

    /// Forgiving decoder: legacy records (V1 / V1.5 without deletion
    /// fields) load with sensible defaults so the user's existing imported
    /// videos don't disappear after upgrade. `processingStatus` defaults
    /// to `.completed` on legacy records — they were already processed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                            = try c.decode(UUID.self, forKey: .id)
        self.originalFilename              = try c.decode(String.self, forKey: .originalFilename)
        self.relativePath                  = try c.decode(String.self, forKey: .relativePath)
        self.importedAt                    = try c.decode(Date.self, forKey: .importedAt)
        self.duration                      = try c.decode(Double.self, forKey: .duration)
        self.batchId                       = try? c.decode(UUID.self, forKey: .batchId)
        self.processingStatus              = (try? c.decode(VideoProcessingStatus.self, forKey: .processingStatus)) ?? .completed
        self.errorMessage                  = try? c.decode(String.self, forKey: .errorMessage)
        self.originalAssetIdentifier       = try? c.decode(String.self, forKey: .originalAssetIdentifier)
        self.wasOriginalDeletedFromPhotos  = (try? c.decode(Bool.self, forKey: .wasOriginalDeletedFromPhotos)) ?? false
        self.deletionErrorMessage          = try? c.decode(String.self, forKey: .deletionErrorMessage)
        self.fileSizeBytes                 = try? c.decode(Int64.self, forKey: .fileSizeBytes)
        // V4.1 — pre-V4.1 records have no detectionMode; nil here means
        // "the next processing pass will auto-detect and persist."
        self.detectionMode                 = try? c.decode(DetectionMode.self, forKey: .detectionMode)
    }
}
