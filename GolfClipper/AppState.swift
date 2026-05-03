// AppState.swift
// Single ObservableObject that holds everything the UI needs. Views read
// from it and call its methods to make things happen. Keeping it in one
// place keeps the architecture easy to follow.
//
// V1.5 multi-video / batch import:
//  - `importedVideo` (singular) became `importedVideos: [ImportedVideo]`.
//  - `analysis` (single-video state) became `batchState`, which carries
//    a per-batch progress snapshot or the post-batch summary.
//  - The pipeline runs sequentially, one video at a time, so we never
//    decode multiple audio tracks concurrently and don't spike memory.
//  - Each video's status (importing / analyzing / done / failed / etc.)
//    is persisted alongside the video itself, so a crash mid-batch doesn't
//    wipe progress.
//  - One video failing never aborts the batch.

import Foundation
import SwiftUI
import AVFoundation
import Photos

// MARK: - Batch state types

/// Live snapshot of a running batch. Drives the progress sheet.
struct BatchProgress: Equatable {
    let total: Int
    var currentIndex: Int = 0                       // 1-based ("Video N of total")
    var currentFilename: String? = nil
    var currentStatus: VideoProcessingStatus = .pending
    var clipsCreated: Int = 0
    var failedCount: Int = 0
    /// V3 — within the .creatingClips phase, how many clips are done /
    /// how many total. 0 / 0 = not in clip-export phase. Drives the
    /// "Creating clip N of M…" line in VideoAnalysisView.
    var currentClipIndex: Int = 0
    var currentClipTotal: Int = 0
    /// V3.5 — within the .validatingMotion phase, how many candidates
    /// have been validated / how many total. Drives the
    /// "Validating swing N of M…" line.
    var currentMotionIndex: Int = 0
    var currentMotionTotal: Int = 0
}

/// Final tally shown after a batch finishes.
struct BatchSummary: Equatable, Hashable {
    let total: Int
    let processed: Int
    let failed: Int
    let totalClipsCreated: Int
    let results: [VideoResult]

    struct VideoResult: Identifiable, Equatable, Hashable {
        var id: UUID { videoId }
        let videoId: UUID
        let filename: String
        let status: VideoProcessingStatus
        let clipCount: Int
        let errorMessage: String?
    }
}

/// Top-level state for the analysis sheet. The home screen presents the
/// sheet whenever this is anything other than `.idle`.
enum BatchState: Equatable {
    case idle
    case running(BatchProgress)
    case completed(BatchSummary)
    case failed(String)

    var isWorking: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // MARK: Published state

    @Published var importedVideos: [ImportedVideo] = []
    @Published var clips: [SwingClip] = []
    @Published var settings: DetectionSettings = .default

    @Published var batchState: BatchState = .idle

    /// Most-recent detection debug data (last processed video in a batch).
    /// Used by SettingsDebugView. Older videos' debug data is overwritten —
    /// V1.5 doesn't surface per-video debug across the whole batch.
    @Published var lastDetectedTimestamps: [Double] = []
    @Published var lastCandidates: [ImpactCandidate] = []
    /// V3 — diagnostics from the last detection run (median ratio,
    /// adaptive threshold, dedup counts, processing time, …).
    @Published var lastDetectionStats: DetectionStats?
    /// V3.5 — per-candidate motion verdict from the most-recent run.
    @Published var lastMotionValidations: [MotionValidation] = []
    /// True when the last run fell back to audio-only because the
    /// camera looked like it was panning. Surfaced in the debug screen.
    @Published var lastMotionCameraMoving: Bool = false

    /// Used by views to surface non-batch errors (alerts).
    @Published var errorMessage: String?

    /// V1.7 — set of source-video IDs whose cleanup banner has been
    /// dismissed for the current app session via "Keep Original".
    /// In-memory only: dies when the app process exits, so relaunching
    /// the app shows the banner again (per spec).
    @Published var dismissedCleanupBannerVideoIDs: Set<UUID> = []

    // MARK: Services

    private let storage = LocalStorageService.shared
    private let importer = VideoImportService()
    private let detector = AudioImpactDetector()
    private let motionValidator = MotionValidator()
    private let exporter = ClipExportService()
    private let saver = PhotosSaveService()
    private let photosDeleter = PhotosDeleteService()
    private let thumbnailer = ThumbnailGenerator()

    // MARK: Init

    init() {
        // Restore state on launch.
        self.importedVideos = storage.loadVideos()
        self.clips = storage.loadClips().sorted { $0.impactTimestamp < $1.impactTimestamp }
        self.settings = storage.loadSettings()

        // V1.7: backfill missing fileSizeBytes for any pre-V1.7 records.
        // The cleanup banner needs the size to motivate ("free up 248 MB"),
        // so we read it lazily from disk on first launch after upgrade.
        backfillMissingFileSizes()
    }

    private func backfillMissingFileSizes() {
        var changed = false
        for i in importedVideos.indices where importedVideos[i].fileSizeBytes == nil {
            let url = importedVideos[i].localFileURL
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let n = attrs[.size] as? NSNumber {
                importedVideos[i].fileSizeBytes = n.int64Value
                changed = true
            }
        }
        if changed { storage.saveVideos(importedVideos) }
    }

    // MARK: - Settings

    func updateSettings(_ new: DetectionSettings) {
        self.settings = new
        storage.saveSettings(new)
    }

    // MARK: - Import (single or batch)

    /// User picked one or more videos from the custom video browser. We
    /// process them sequentially: import → audio check → detect →
    /// export → thumbnails. Single-video import is just a batch of
    /// size 1, so the rest of the app sees no special case.
    func importVideos(fromAssetIdentifiers ids: [String]) async {
        guard !ids.isEmpty else { return }
        errorMessage = nil

        let batchId = UUID()
        var progress = BatchProgress(total: ids.count)
        batchState = .running(progress)

        var perVideoResults: [BatchSummary.VideoResult] = []
        var totalClipsCreated = 0
        var failedCount = 0

        for (idx, assetID) in ids.enumerated() {
            progress.currentIndex = idx + 1
            progress.currentFilename = nil
            progress.currentStatus = .importing
            batchState = .running(progress)

            // --- Step A: copy from Photos into our Documents folder. ---
            let importedVideo: ImportedVideo
            do {
                var v = try await importer.importVideo(fromAssetIdentifier: assetID)
                v.batchId = batchId
                v.processingStatus = .importing
                importedVideo = v
            } catch {
                failedCount += 1
                progress.failedCount += 1
                batchState = .running(progress)
                perVideoResults.append(.init(
                    videoId: UUID(),
                    filename: "(import failed)",
                    status: .failed,
                    clipCount: 0,
                    errorMessage: error.localizedDescription
                ))
                continue
            }

            // Persist the video record immediately so a crash mid-batch
            // doesn't lose it. (We can re-process it later; the file is
            // already on disk at this point.)
            self.importedVideos.append(importedVideo)
            storage.saveVideos(self.importedVideos)
            progress.currentFilename = importedVideo.originalFilename

            // --- Step B: process the rest of the pipeline. ---
            let outcome = await processVideo(importedVideo) { newStatus in
                self.updateVideoStatus(id: importedVideo.id, status: newStatus, errorMessage: nil)
                progress.currentStatus = newStatus
                self.batchState = .running(progress)
            }

            switch outcome {
            case .success(let clipsAdded):
                progress.clipsCreated += clipsAdded
                totalClipsCreated += clipsAdded
                batchState = .running(progress)
                self.updateVideoStatus(id: importedVideo.id, status: .completed, errorMessage: nil)
                perVideoResults.append(.init(
                    videoId: importedVideo.id,
                    filename: importedVideo.originalFilename,
                    status: .completed,
                    clipCount: clipsAdded,
                    errorMessage: nil
                ))

            case .noAudio:
                self.updateVideoStatus(id: importedVideo.id, status: .noAudio,
                                       errorMessage: "No audio track")
                perVideoResults.append(.init(
                    videoId: importedVideo.id,
                    filename: importedVideo.originalFilename,
                    status: .noAudio,
                    clipCount: 0,
                    errorMessage: "No audio track"
                ))

            case .noShots:
                self.updateVideoStatus(id: importedVideo.id, status: .noShotsFound, errorMessage: nil)
                perVideoResults.append(.init(
                    videoId: importedVideo.id,
                    filename: importedVideo.originalFilename,
                    status: .noShotsFound,
                    clipCount: 0,
                    errorMessage: nil
                ))

            case .failure(let err):
                failedCount += 1
                progress.failedCount += 1
                batchState = .running(progress)
                self.updateVideoStatus(id: importedVideo.id, status: .failed,
                                       errorMessage: err.localizedDescription)
                perVideoResults.append(.init(
                    videoId: importedVideo.id,
                    filename: importedVideo.originalFilename,
                    status: .failed,
                    clipCount: 0,
                    errorMessage: err.localizedDescription
                ))
            }
        }

        let summary = BatchSummary(
            total: ids.count,
            processed: ids.count - failedCount,
            failed: failedCount,
            totalClipsCreated: totalClipsCreated,
            results: perVideoResults
        )
        batchState = .completed(summary)
    }

    // MARK: - Shared-container import (V6 — Share Extension handoff)

    /// Pulls anything the NiceShotShare extension dropped into the App
    /// Group's `pending/` directory into the regular import pipeline.
    /// Called from `GolfClipperApp` on launch + on every foreground
    /// transition. No-ops if there's nothing pending or if a batch is
    /// already running (in which case the next foreground will retry).
    ///
    /// V6.1 — descriptor-based handoff. The extension writes a small
    /// JSON descriptor naming either a PHAsset identifier (fast path)
    /// or a copied video file (slow fallback). Asset descriptors reuse
    /// the existing `VideoImportService.importVideo(fromAssetIdentifier:)`
    /// — same code path the in-app browser uses, so the audio detection,
    /// motion validation, and clip export are byte-for-byte identical.
    /// File descriptors use the V6 fallback path that moves directly
    /// from the App Group into Documents.
    func importPendingSharedVideos() async {
        // V6.4 diagnostic — fires on EVERY foreground tick so the user
        // can confirm App Group reachability without a special build.
        // If `container=<nil>`, the App Group entitlement isn't actually
        // active in the runtime profile (likely Personal Team blocking
        // it) and nothing the extension writes can be read here.
        let containerStr = SharedContainerImporter.containerURL?.path ?? "<nil>"
        let pendingDirStr = SharedContainerImporter.pendingDirectoryURL?.path ?? "<nil>"
        let earlyDescriptors = SharedContainerImporter.pendingDescriptors()
        NSLog("[NiceShot] AppGroup diag | container=\(containerStr) | pendingDir=\(pendingDirStr) | descriptors=\(earlyDescriptors.count)")

        // Don't interrupt an in-flight batch. The pending files stay put;
        // we'll come back for them on the next foreground tick.
        if case .running = batchState { return }

        let descriptors = earlyDescriptors
        guard !descriptors.isEmpty else { return }

        errorMessage = nil
        let batchId = UUID()
        var progress = BatchProgress(total: descriptors.count)
        batchState = .running(progress)

        var perVideoResults: [BatchSummary.VideoResult] = []
        var totalClipsCreated = 0
        var failedCount = 0

        for (idx, descriptor) in descriptors.enumerated() {
            progress.currentIndex = idx + 1
            progress.currentFilename = descriptor.filename
            progress.currentStatus = .importing
            batchState = .running(progress)

            // --- Step A: produce an ImportedVideo from the descriptor. ---
            // For asset / filename descriptors we reuse the same
            // VideoImportService method the in-app browser calls — the
            // heavy iCloud download happens here, in the main app, with
            // the analysis sheet already showing progress.
            let importedVideo: ImportedVideo
            do {
                switch descriptor.kind {
                case .filename(let name):
                    // V6.2 — extension shipped only the filename. Look
                    // up the matching PHAsset on a background queue
                    // (the lookup involves per-asset metadata fetches
                    // that Photos warns about doing on main).
                    guard let identifier = await Self.findAssetIdentifier(matching: name) else {
                        throw NSError(domain: "SharedImport", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Couldn't find a matching video in Photos for '\(name)'. Try sharing again or use the in-app picker."])
                    }
                    var v = try await importer.importVideo(fromAssetIdentifier: identifier)
                    v.batchId = batchId
                    v.processingStatus = .importing
                    importedVideo = v
                case .asset(let identifier):
                    var v = try await importer.importVideo(fromAssetIdentifier: identifier)
                    v.batchId = batchId
                    v.processingStatus = .importing
                    importedVideo = v
                case .file(let url):
                    importedVideo = try await ingestSharedVideo(at: url,
                                                                batchId: batchId)
                }
            } catch {
                failedCount += 1
                progress.failedCount += 1
                batchState = .running(progress)
                perVideoResults.append(.init(
                    videoId: UUID(),
                    filename: descriptor.filename,
                    status: .failed,
                    clipCount: 0,
                    errorMessage: error.localizedDescription
                ))
                // Even on failure, drop the descriptor so we don't
                // infinitely retry a corrupt entry every foreground.
                SharedContainerImporter.cleanup(descriptor)
                continue
            }

            self.importedVideos.append(importedVideo)
            storage.saveVideos(self.importedVideos)
            progress.currentFilename = importedVideo.originalFilename

            // Successfully ingested — remove the descriptor now so a
            // crash mid-pipeline doesn't cause a duplicate import next
            // launch. (For asset descriptors the original Photos asset
            // is unchanged; for file descriptors the inline copy is
            // deleted by cleanup().)
            SharedContainerImporter.cleanup(descriptor)

            // --- Step B: process the rest of the pipeline. ---
            let outcome = await processVideo(importedVideo) { newStatus in
                self.updateVideoStatus(id: importedVideo.id, status: newStatus, errorMessage: nil)
                progress.currentStatus = newStatus
                self.batchState = .running(progress)
            }

            switch outcome {
            case .success(let clipsAdded):
                progress.clipsCreated += clipsAdded
                totalClipsCreated += clipsAdded
                batchState = .running(progress)
                self.updateVideoStatus(id: importedVideo.id, status: .completed, errorMessage: nil)
                perVideoResults.append(.init(
                    videoId: importedVideo.id,
                    filename: importedVideo.originalFilename,
                    status: .completed,
                    clipCount: clipsAdded,
                    errorMessage: nil
                ))
            case .noAudio:
                self.updateVideoStatus(id: importedVideo.id, status: .noAudio,
                                       errorMessage: "No audio track")
                perVideoResults.append(.init(
                    videoId: importedVideo.id,
                    filename: importedVideo.originalFilename,
                    status: .noAudio,
                    clipCount: 0,
                    errorMessage: "No audio track"
                ))
            case .noShots:
                self.updateVideoStatus(id: importedVideo.id, status: .noShotsFound, errorMessage: nil)
                perVideoResults.append(.init(
                    videoId: importedVideo.id,
                    filename: importedVideo.originalFilename,
                    status: .noShotsFound,
                    clipCount: 0,
                    errorMessage: nil
                ))
            case .failure(let err):
                failedCount += 1
                progress.failedCount += 1
                batchState = .running(progress)
                self.updateVideoStatus(id: importedVideo.id, status: .failed,
                                       errorMessage: err.localizedDescription)
                perVideoResults.append(.init(
                    videoId: importedVideo.id,
                    filename: importedVideo.originalFilename,
                    status: .failed,
                    clipCount: 0,
                    errorMessage: err.localizedDescription
                ))
            }
        }

        let summary = BatchSummary(
            total: descriptors.count,
            processed: descriptors.count - failedCount,
            failed: failedCount,
            totalClipsCreated: totalClipsCreated,
            results: perVideoResults
        )
        batchState = .completed(summary)
    }

    /// V6.2 — Resolve a Photos suggestedName to a PHAsset localIdentifier.
    /// Runs on a detached `Task` so the per-asset metadata fetches (which
    /// Photos warns about on the main queue) happen off the UI thread.
    /// Capped at 250 most-recent videos: real-world shares are nearly
    /// always recent, and the cap bounds worst-case latency on libraries
    /// with thousands of clips.
    static func findAssetIdentifier(matching filename: String) async -> String? {
        guard !filename.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: .video, options: options)
            var found: String?
            let maxScan = 250
            result.enumerateObjects { asset, idx, stop in
                if idx >= maxScan {
                    stop.pointee = true
                    return
                }
                let resources = PHAssetResource.assetResources(for: asset)
                if resources.contains(where: { $0.originalFilename == filename }) {
                    found = asset.localIdentifier
                    stop.pointee = true
                }
            }
            return found
        }.value
    }

    /// Move a video out of the App Group `pending/` directory into the
    /// app's Documents/ImportedVideos folder, capture file metadata, and
    /// return a fresh ImportedVideo record. No PHAsset identifier is
    /// available for shared imports — the cleanup banner will see this
    /// as `originalAssetIdentifier == nil` and quietly hide the
    /// "Delete Original from Photos" affordance, which is correct.
    private func ingestSharedVideo(at sourceURL: URL,
                                   batchId: UUID) async throws -> ImportedVideo {
        // Strip the Share Extension's UUID prefix (added to avoid pending
        // collisions); the user-facing displayName is date-derived anyway,
        // so there's no value carrying it through.
        let sourceName = sourceURL.lastPathComponent
        let originalName: String = {
            // Pattern: "<UUID>_<originalFilename>"
            if let underscoreIdx = sourceName.firstIndex(of: "_") {
                return String(sourceName[sourceName.index(after: underscoreIdx)...])
            }
            return sourceName
        }()

        let videosFolder = FileManagerHelpers.videosFolderURL
        let safeName = "\(UUID().uuidString)_\(originalName)"
        let destURL = videosFolder.appendingPathComponent(safeName)

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
        } catch {
            // Fall back to copy + delete in case the App Group container
            // and Documents are on a boundary that doesn't allow rename.
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let asset = AVURLAsset(url: destURL)
        let cm = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(cm)
        guard duration.isFinite, duration > 0 else {
            try? FileManager.default.removeItem(at: destURL)
            throw NSError(domain: "SharedImport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read video duration"])
        }

        let fileSizeBytes: Int64? = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
                  let n = attrs[.size] as? NSNumber else { return nil }
            return n.int64Value
        }()

        let relPath = FileManagerHelpers.relativePath(for: destURL)
        return ImportedVideo(
            originalFilename: originalName,
            relativePath: relPath,
            importedAt: Date(),
            duration: duration,
            batchId: batchId,
            processingStatus: .importing,
            originalAssetIdentifier: nil,    // V6 — no Photos reference for shared imports
            fileSizeBytes: fileSizeBytes
        )
    }

    // MARK: - Per-video pipeline

    /// Possible outcomes of running the pipeline on one video. We use this
    /// instead of throwing because we want each terminal state to flow
    /// through the same downstream summary plumbing.
    private enum VideoOutcome {
        case success(clipsAdded: Int)
        case noAudio
        case noShots
        case failure(Error)
    }

    /// Audio check → detect → export → thumbnails for one already-imported
    /// video. `progress` is called whenever the per-video status changes.
    ///
    /// V3.8 short-video accommodations (an intentional 7–15s recording
    /// is almost certainly one swing — the algorithm should not hide it
    /// behind generic-purpose filters):
    ///   • <30s videos: min spacing forced to 2.0s. The default 6.0s
    ///     could collapse two real peaks in a 7s clip into one.
    ///   • <15s videos with at least one audio peak: motion validation
    ///     is skipped. The validator's peak/min ratio gate penalizes
    ///     phone-propped recordings where the player is in motion
    ///     before/after, and on a short intentional recording the
    ///     false-negative cost dwarfs the false-positive benefit.
    ///   • <15s videos that still produce zero clips: fall back to the
    ///     single loudest audio moment, even if it never crossed
    ///     threshold. Better one questionable clip than nothing.
    private func processVideo(_ video: ImportedVideo,
                              progress: @escaping (VideoProcessingStatus) -> Void) async -> VideoOutcome {
        // 1. Audio check. (No audio = nothing for the detector to do.)
        progress(.analyzing)
        let hasAudio = await importer.videoHasAudioTrack(video)
        if !hasAudio { return .noAudio }

        // V3.8 — derive an effective settings struct that respects the
        // user's preset/multiplier choices but loosens min-spacing for
        // short clips. The user-visible setting in Settings/Debug is
        // unchanged; this is purely a per-video adjustment.
        let effectiveSettings = adjustedSettings(for: video, base: settings)

        // 2. Run impact detection.
        progress(.detectingShots)
        let result: ImpactDetectionResult
        do {
            result = try await detector.detectImpacts(in: video, settings: effectiveSettings)
        } catch {
            return .failure(error)
        }

        // Stash debug data for the most-recent video. The Settings/Debug
        // screen only shows one video's worth — V1.5 doesn't try to keep
        // per-video debug history across the whole batch.
        self.lastDetectedTimestamps = result.impactTimestamps
        self.lastCandidates = result.candidates
        self.lastDetectionStats = result.stats

        // 3. Motion validation. V3.8 — skipped for under-15s videos
        //    that already have at least one audio peak (see header comment).
        let isShortVideo = video.duration < Self.shortVideoThresholdSeconds
        let runMotionValidation = effectiveSettings.motionValidationEnabled
            && !(isShortVideo && !result.impactTimestamps.isEmpty)

        var timestampsToExport: [Double]
        let motionConfirmedCount: Int
        if runMotionValidation && !result.impactTimestamps.isEmpty {
            progress(.validatingMotion)
            let validation = await motionValidator.validate(
                videoURL: video.localFileURL,
                videoDuration: video.duration,
                candidates: result.impactTimestamps,
                threshold: effectiveSettings.motionThreshold,
                progress: { [weak self] done, total in
                    Task { @MainActor in
                        self?.updateMotionProgress(done: done, total: total)
                    }
                }
            )
            self.updateMotionProgress(done: 0, total: 0)
            self.lastMotionValidations = validation.allValidations
            self.lastMotionCameraMoving = validation.cameraMovingDetected
            timestampsToExport = validation.validatedTimestamps
            motionConfirmedCount = validation.validatedTimestamps.count
        } else {
            self.lastMotionValidations = []
            self.lastMotionCameraMoving = false
            timestampsToExport = result.impactTimestamps
            // motionConfirmedCount only describes the validator's verdict.
            // When validation didn't run, it's "n/a" — we represent that
            // as audio-peak count (i.e. nothing was rejected). The
            // PIPELINE SUMMARY line below labels it as skipped.
            motionConfirmedCount = result.impactTimestamps.count
        }

        // V3.8 — short-video fallback. If the whole pipeline produced
        // nothing AND the video is short enough that "user filmed one
        // swing on purpose" is the dominant case, take the loudest audio
        // moment regardless of threshold.
        var fallbackUsed = false
        if timestampsToExport.isEmpty,
           isShortVideo,
           let loudest = result.loudestWindowTime {
            print(String(format: "[NiceShot] Fallback: using loudest peak at %.2fs for short video", loudest))
            timestampsToExport = [loudest]
            fallbackUsed = true
        }

        if timestampsToExport.isEmpty {
            printPipelineSummary(audio: result.stats.rawPeakCount,
                                 dedup: result.stats.after500msDedup,
                                 spacing: result.stats.afterMinSpacing,
                                 motion: motionConfirmedCount,
                                 motionRan: runMotionValidation,
                                 finalClips: 0,
                                 fallback: false)
            return .noShots
        }

        // 4. Export clips. Per-clip progress drives "Creating clip N of M…"
        //    in the analysis sheet. The closure fires from a non-main
        //    context, so we hop to MainActor before touching @Published.
        progress(.creatingClips)
        let newClips = await exporter.exportClips(
            from: video,
            impactTimes: timestampsToExport,
            settings: settings,
            isManual: false,
            progress: { [weak self] done, total in
                Task { @MainActor in
                    self?.updateClipExportProgress(done: done, total: total)
                }
            }
        )
        // Clear the per-clip counter once we leave the clip-export phase.
        self.updateClipExportProgress(done: 0, total: 0)

        // 4. Thumbnails.
        var withThumbs: [SwingClip] = []
        for var clip in newClips {
            if let thumbURL = await thumbnailer.generateThumbnail(for: clip) {
                clip.thumbnailRelativePath = FileManagerHelpers.relativePath(for: thumbURL)
            }
            withThumbs.append(clip)
        }

        self.clips.append(contentsOf: withThumbs)
        self.clips.sort { $0.impactTimestamp < $1.impactTimestamp }
        storage.saveClips(self.clips)

        printPipelineSummary(audio: result.stats.rawPeakCount,
                             dedup: result.stats.after500msDedup,
                             spacing: result.stats.afterMinSpacing,
                             motion: motionConfirmedCount,
                             motionRan: runMotionValidation,
                             finalClips: withThumbs.count,
                             fallback: fallbackUsed)

        return .success(clipsAdded: withThumbs.count)
    }

    /// V3.8 — videos shorter than this get the short-video accommodations
    /// (loosened spacing, skipped motion validation, loudest-peak fallback).
    /// 15s is short enough to confidently say "user filmed one swing on
    /// purpose" and long enough to fit a full pre/post-impact window.
    private static let shortVideoThresholdSeconds: Double = 15.0

    /// V3.8 — for videos under 30s, force min-spacing down to 2.0s so a
    /// short recording with two real peaks (e.g. mishit + reset whack)
    /// doesn't lose the second one to the default 6.0s cooldown.
    private func adjustedSettings(for video: ImportedVideo,
                                  base: DetectionSettings) -> DetectionSettings {
        guard video.duration < 30 else { return base }
        var s = base
        s.minimumSpacingSeconds = min(2.0, base.minimumSpacingSeconds)
        return s
    }

    /// One-line per-video summary that always fires. Shows where the
    /// pipeline lost candidates between stages so detection can be tuned
    /// without re-reading the whole log block above. Marked with a
    /// trailing `(fallback)` when the short-video loudest-peak rescue
    /// salvaged the run.
    private func printPipelineSummary(audio: Int,
                                      dedup: Int,
                                      spacing: Int,
                                      motion: Int,
                                      motionRan: Bool,
                                      finalClips: Int,
                                      fallback: Bool) {
        let motionPart = motionRan ? "\(motion)" : "skipped"
        let suffix = fallback ? " (fallback)" : ""
        print("[NiceShot] PIPELINE SUMMARY: audio=\(audio) → dedup=\(dedup) → spacing=\(spacing) → motion=\(motionPart) → final clips=\(finalClips)\(suffix)")
    }

    // MARK: - Re-analyze (Settings → Re-analyze button)

    /// Wipe all clips and re-run detection on every imported video using
    /// the current settings. Imported videos themselves are kept.
    func reanalyzeAllVideos() async {
        guard !importedVideos.isEmpty else { return }
        errorMessage = nil

        // Wipe existing clips and their files.
        for clip in clips {
            FileManagerHelpers.deleteFile(atRelativePath: clip.relativePath)
            if let t = clip.thumbnailRelativePath {
                FileManagerHelpers.deleteFile(atRelativePath: t)
            }
        }
        clips = []
        storage.saveClips([])

        // Reset all videos to .pending so the UI reflects the fresh run.
        for i in importedVideos.indices {
            importedVideos[i].processingStatus = .pending
            importedVideos[i].errorMessage = nil
        }
        storage.saveVideos(importedVideos)

        var progress = BatchProgress(total: importedVideos.count)
        batchState = .running(progress)
        var perVideoResults: [BatchSummary.VideoResult] = []
        var totalClipsCreated = 0
        var failedCount = 0

        for (idx, video) in importedVideos.enumerated() {
            progress.currentIndex = idx + 1
            progress.currentFilename = video.originalFilename
            progress.currentStatus = .analyzing
            batchState = .running(progress)

            let outcome = await processVideo(video) { newStatus in
                self.updateVideoStatus(id: video.id, status: newStatus, errorMessage: nil)
                progress.currentStatus = newStatus
                self.batchState = .running(progress)
            }

            switch outcome {
            case .success(let n):
                progress.clipsCreated += n
                totalClipsCreated += n
                batchState = .running(progress)
                self.updateVideoStatus(id: video.id, status: .completed, errorMessage: nil)
                perVideoResults.append(.init(
                    videoId: video.id,
                    filename: video.originalFilename,
                    status: .completed,
                    clipCount: n,
                    errorMessage: nil
                ))
            case .noAudio:
                self.updateVideoStatus(id: video.id, status: .noAudio,
                                       errorMessage: "No audio track")
                perVideoResults.append(.init(
                    videoId: video.id,
                    filename: video.originalFilename,
                    status: .noAudio,
                    clipCount: 0,
                    errorMessage: "No audio track"
                ))
            case .noShots:
                self.updateVideoStatus(id: video.id, status: .noShotsFound, errorMessage: nil)
                perVideoResults.append(.init(
                    videoId: video.id,
                    filename: video.originalFilename,
                    status: .noShotsFound,
                    clipCount: 0,
                    errorMessage: nil
                ))
            case .failure(let err):
                failedCount += 1
                progress.failedCount += 1
                batchState = .running(progress)
                self.updateVideoStatus(id: video.id, status: .failed,
                                       errorMessage: err.localizedDescription)
                perVideoResults.append(.init(
                    videoId: video.id,
                    filename: video.originalFilename,
                    status: .failed,
                    clipCount: 0,
                    errorMessage: err.localizedDescription
                ))
            }
        }

        let summary = BatchSummary(
            total: importedVideos.count,
            processed: importedVideos.count - failedCount,
            failed: failedCount,
            totalClipsCreated: totalClipsCreated,
            results: perVideoResults
        )
        batchState = .completed(summary)
    }

    // MARK: - Manual clip

    /// Build a manual clip from the chosen source video at the given time.
    func createManualClip(forVideo video: ImportedVideo, atTime time: Double) async {
        errorMessage = nil
        do {
            var clip = try await exporter.exportClip(
                from: video,
                impactTime: time,
                settings: settings,
                isManual: true
            )
            if let thumbURL = await thumbnailer.generateThumbnail(for: clip) {
                clip.thumbnailRelativePath = FileManagerHelpers.relativePath(for: thumbURL)
            }
            self.clips.append(clip)
            self.clips.sort { $0.impactTimestamp < $1.impactTimestamp }
            storage.saveClips(self.clips)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Delete

    func deleteClip(_ clip: SwingClip) {
        FileManagerHelpers.deleteFile(atRelativePath: clip.relativePath)
        if let thumb = clip.thumbnailRelativePath {
            FileManagerHelpers.deleteFile(atRelativePath: thumb)
        }
        clips.removeAll { $0.id == clip.id }
        storage.saveClips(clips)
    }

    /// Delete a single source video and all clips that came from it.
    func deleteVideo(_ video: ImportedVideo) {
        FileManagerHelpers.deleteFile(atRelativePath: video.relativePath)
        let toRemove = clips.filter { $0.sourceVideoId == video.id }
        for clip in toRemove {
            FileManagerHelpers.deleteFile(atRelativePath: clip.relativePath)
            if let t = clip.thumbnailRelativePath {
                FileManagerHelpers.deleteFile(atRelativePath: t)
            }
        }
        clips.removeAll { $0.sourceVideoId == video.id }
        importedVideos.removeAll { $0.id == video.id }
        storage.saveClips(clips)
        storage.saveVideos(importedVideos)
    }

    /// Wipe everything — every imported video and every clip.
    func deleteAllClipsAndVideos() {
        for clip in clips {
            FileManagerHelpers.deleteFile(atRelativePath: clip.relativePath)
            if let t = clip.thumbnailRelativePath {
                FileManagerHelpers.deleteFile(atRelativePath: t)
            }
        }
        clips = []
        for video in importedVideos {
            FileManagerHelpers.deleteFile(atRelativePath: video.relativePath)
        }
        importedVideos = []
        lastDetectedTimestamps = []
        lastCandidates = []
        lastDetectionStats = nil
        lastMotionValidations = []
        lastMotionCameraMoving = false
        batchState = .idle
        storage.saveClips([])
        storage.saveVideos([])
    }

    // MARK: - Save to Photos

    func saveClipToPhotos(_ clip: SwingClip) async {
        do {
            try await saver.saveVideoToPhotos(at: clip.localFileURL)
            if let idx = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[idx].isSavedToPhotos = true
                storage.saveClips(clips)
                // V1.7: any new save un-dismisses the banner so users see
                // it again ("next time they save clips" — per spec).
                dismissedCleanupBannerVideoIDs.removeAll()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAllClipsToPhotos() async {
        for clip in clips where !clip.isSavedToPhotos {
            await saveClipToPhotos(clip)
        }
    }

    // MARK: - Original-video cleanup (V1.7 banner)

    /// Videos eligible for the post-save cleanup banner. The rule is
    /// looser than V1.6's modal alert: we show the banner once at least
    /// ONE clip from the video is saved to Photos. The banner replaces
    /// the V1.6 alert entirely.
    ///
    /// View-layer filtering removes any video the user has tapped
    /// "Keep Original" on (see `dismissedCleanupBannerVideoIDs`).
    var videosWithCleanupBanner: [ImportedVideo] {
        importedVideos.filter { video in
            guard !video.wasOriginalDeletedFromPhotos else { return false }
            guard video.originalAssetIdentifier != nil else { return false }
            return clips.contains { $0.sourceVideoId == video.id && $0.isSavedToPhotos }
        }
    }

    /// Outcome of `deleteOriginal(forVideo:)`. View consumes this to
    /// decide whether to show a 3-second confirmation toast, surface an
    /// error, or stay silent (user cancelled the system dialog).
    enum SingleOriginalDeleteResult: Equatable {
        case deleted
        case userCancelled
        case failed(String)
        case missingIdentifier
    }

    /// Delete one source video's original from the Photos library. The
    /// system confirmation dialog (Apple) appears as the final safeguard.
    /// On success, marks `wasOriginalDeletedFromPhotos = true`.
    @discardableResult
    func deleteOriginal(forVideo video: ImportedVideo) async -> SingleOriginalDeleteResult {
        guard let assetID = video.originalAssetIdentifier else {
            return .missingIdentifier
        }

        let result: PhotosDeleteResult
        do {
            result = try await photosDeleter.deleteOriginal(assetIdentifier: assetID)
        } catch {
            // Permission denied — show a global alert; don't touch the record.
            errorMessage = error.localizedDescription
            return .failed(error.localizedDescription)
        }

        switch result.outcome {
        case .deleted:
            updateVideoDeletionStatus(id: video.id, deleted: true, errorMessage: nil)
            return .deleted
        case .notFound:
            // Asset is already gone in Photos. From our POV, that's a
            // success — there's nothing left to delete; mark and move on.
            updateVideoDeletionStatus(id: video.id, deleted: true, errorMessage: nil)
            return .deleted
        case .userCancelled:
            // Silent. Record unchanged. Banner stays visible.
            return .userCancelled
        case .failed(let msg):
            updateVideoDeletionStatus(id: video.id, deleted: false, errorMessage: msg)
            return .failed(msg)
        }
    }

    /// User tapped "Keep Original" — hide that video's banner for the
    /// rest of this app session. State is intentionally NOT persisted.
    func dismissCleanupBanner(forVideo video: ImportedVideo) {
        dismissedCleanupBannerVideoIDs.insert(video.id)
    }

    // MARK: - Helpers

    /// Updates the per-clip export counter inside an in-flight batch
    /// progress, so VideoAnalysisView can render "Creating clip N of M…".
    /// Safe to call repeatedly; no-op if we're not in a running batch.
    private func updateClipExportProgress(done: Int, total: Int) {
        if case .running(var bp) = batchState {
            bp.currentClipIndex = done
            bp.currentClipTotal = total
            batchState = .running(bp)
        }
    }

    /// V3.5 sibling of updateClipExportProgress — drives "Validating
    /// swing N of M…" during the motion-validation phase.
    private func updateMotionProgress(done: Int, total: Int) {
        if case .running(var bp) = batchState {
            bp.currentMotionIndex = done
            bp.currentMotionTotal = total
            batchState = .running(bp)
        }
    }

    private func updateVideoStatus(id: UUID,
                                   status: VideoProcessingStatus,
                                   errorMessage: String?) {
        guard let idx = importedVideos.firstIndex(where: { $0.id == id }) else { return }
        importedVideos[idx].processingStatus = status
        importedVideos[idx].errorMessage = errorMessage
        storage.saveVideos(importedVideos)
    }

    private func updateVideoDeletionStatus(id: UUID,
                                           deleted: Bool,
                                           errorMessage: String?) {
        guard let idx = importedVideos.firstIndex(where: { $0.id == id }) else { return }
        importedVideos[idx].wasOriginalDeletedFromPhotos = deleted
        importedVideos[idx].deletionErrorMessage = errorMessage
        storage.saveVideos(importedVideos)
    }
}
