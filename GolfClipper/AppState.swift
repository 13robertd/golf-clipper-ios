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

        // V4.1 — configure the audio session ONCE at app launch.
        // Default is .soloAmbient which respects the silent switch and
        // is wrong for a video-playback app; users expect tapping a clip
        // to produce sound regardless of the ringer switch. .playback +
        // .moviePlayback is Apple's recommended pairing for a video
        // player. Configuring here rather than in each player view
        // keeps the session in a single known state for the app's
        // lifetime — VideoPlayer instances inherit it automatically.
        Self.configureAudioSession()
    }

    /// V4.1 — One-time AVAudioSession setup. .playback ignores the
    /// silent switch (correct for explicit video playback) and pauses
    /// other audio while ours plays. Background-audio entitlements are
    /// intentionally NOT set, so iOS suspends playback when the app
    /// backgrounds — matches the spec ("Background the app → audio stops").
    private static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            print("[NiceShot] AVAudioSession configured: .playback / .moviePlayback (active)")
        } catch {
            // Simulators occasionally refuse activation; don't crash.
            // On a real device the failure is rare; surface in logs and
            // playback will fall back to whatever category iOS defaults to.
            print("[NiceShot] AVAudioSession setup failed: \(error.localizedDescription)")
        }
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
                    NSLog("[NiceShot] Shared import: looking up PHAsset for filename='\(name)'")
                    guard let identifier = await Self.findAssetIdentifier(matching: name) else {
                        NSLog("[NiceShot] Shared import: lookup MISSED for filename='\(name)' — no asset found in last 250 videos")
                        throw NSError(domain: "SharedImport", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Couldn't find a matching video in Photos for '\(name)'. Try sharing again or use the in-app picker."])
                    }
                    NSLog("[NiceShot] Shared import: matched filename='\(name)' to assetID=\(identifier) — calling importer")
                    var v = try await importer.importVideo(fromAssetIdentifier: identifier)
                    NSLog("[NiceShot] Shared import: importer returned ImportedVideo for assetID=\(identifier)")
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
    /// Capped at 1000 most-recent videos.
    ///
    /// V6.5 — case-insensitive match + basename fallback (try matching
    /// without extension if exact match misses). On a complete miss, log
    /// the first 10 filenames we did see so the user can see what's in
    /// the scan window vs what we were looking for.
    static func findAssetIdentifier(matching filename: String) async -> String? {
        guard !filename.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: .video, options: options)

            let target = filename.lowercased()
            let targetBasename = (filename as NSString).deletingPathExtension.lowercased()

            var found: String?
            var sampledFilenames: [String] = []
            let maxScan = 1000
            let sampleSize = 10

            result.enumerateObjects { asset, idx, stop in
                if idx >= maxScan {
                    stop.pointee = true
                    return
                }
                let resources = PHAssetResource.assetResources(for: asset)
                for r in resources {
                    if sampledFilenames.count < sampleSize {
                        sampledFilenames.append(r.originalFilename)
                    }
                    let candidate = r.originalFilename.lowercased()
                    if candidate == target {
                        found = asset.localIdentifier
                        stop.pointee = true
                        return
                    }
                    let candidateBasename = (r.originalFilename as NSString).deletingPathExtension.lowercased()
                    if candidateBasename == targetBasename {
                        found = asset.localIdentifier
                        stop.pointee = true
                        return
                    }
                }
            }

            if found == nil {
                NSLog("[NiceShot] findAssetIdentifier: '\(filename)' not found in last \(maxScan) videos. First \(sampledFilenames.count) PHAssetResource filenames seen: \(sampledFilenames)")
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
    ///
    /// V4.1 — mode selection. Each video runs under one of two
    /// `DetectionMode` tunings:
    ///   • `singleSwing`: 2.0s min-spacing, loudest-peak fallback on any
    ///     duration. Defaulted for videos shorter than 30s.
    ///   • `rangeSession`: 6.0s min-spacing, loudest-peak fallback only
    ///     on <15s videos. Defaulted for videos ≥30s.
    /// The auto-detected mode is persisted on the ImportedVideo on the
    /// first run so future heuristic changes don't silently shift
    /// behavior. The user can override via the chip on the results UI.
    private func processVideo(_ video: ImportedVideo,
                              progress: @escaping (VideoProcessingStatus) -> Void) async -> VideoOutcome {
        // 1. Audio check. (No audio = nothing for the detector to do.)
        progress(.analyzing)
        let hasAudio = await importer.videoHasAudioTrack(video)
        if !hasAudio { return .noAudio }

        // V4.1 — Resolve mode. Prefer the persisted value; only fall back
        // to auto-detect if this is the first time we've processed the
        // video (or it was imported pre-V4.1). Persist back the choice
        // immediately so subsequent reads (UI chip, reanalyze) see it.
        let mode = video.detectionMode ?? DetectionMode.autoDetect(forDuration: video.duration)
        if video.detectionMode == nil {
            updateVideoMode(id: video.id, mode: mode)
        }
        print("[NiceShot] Detection mode: \(mode.rawValue) (duration \(String(format: "%.1f", video.duration))s, \(video.detectionMode == nil ? "auto-detected" : "persisted"))")

        // V3.8 + V4.1 — derive effective settings. Mode overrides the
        // user's min-spacing; the V3.8 short-video clamp still applies on
        // top. Audio multiplier is unchanged (user's preset/override
        // still wins; modes don't differ on threshold).
        let effectiveSettings = adjustedSettings(for: video, base: settings, mode: mode)

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

        // V3.10 + V3.11 + V3.12 pipeline:
        //   1. Audio threshold detection (existing) — result has timestamps
        //      + per-candidate energyRatio + transient verdict (attack /
        //      duration / isImpactLike) annotated by the detector.
        //   2. Pre-reject doomed candidates BEFORE dominance check —
        //      zero-prefix (t < 0.5s, motion can't validate) and speech-
        //      like (transient says no). Including them as "competitors"
        //      in the dominance comparison inflates the next-strongest
        //      denominator and blocks legitimate impacts from auto-
        //      confirmation, even though they can't produce clips.
        //   3. Dominant-peak auto-confirm among the pre-filtered set —
        //      if one candidate is ≥2× the next (or it's the only
        //      survivor), bypass motion validation.
        //   4. Motion validation for non-dominant pre-filter survivors.

        // Step 2: pre-filter — drop candidates doomed by transient (speech)
        // or by zero-prefix prediction (impact at t < 0.5s, motion can't
        // validate). The result is `validatableCandidates` — the set of
        // timestamps worth carrying through dominance and motion.
        let transientByTime: [Double: Bool] = Dictionary(
            uniqueKeysWithValues: result.candidates
                .filter { $0.accepted }
                .compactMap { c in c.isImpactLike.map { (c.time, $0) } }
        )
        let validatableCandidates = result.impactTimestamps.filter { time in
            // Zero-prefix prediction: motion val can't validate t < 0.5s
            // (frame extraction clamps to 0, producing duplicate frames
            // and zero-valued intervals). Skip these now so they don't
            // inflate the dominance denominator.
            if time < DetectionConstants.zeroPrefixPredictionThresholdSeconds {
                DetectionConstants.verboseLog(String(format: "[NiceShot] Pre-filter: rejecting %.2fs (t < %.1fs — motion validator can't validate)",
                                                      time, DetectionConstants.zeroPrefixPredictionThresholdSeconds))
                return false
            }
            // Transient: drop speech-like sounds.
            if let entry = transientByTime.first(where: { abs($0.key - time) < 0.05 }),
               entry.value == false {
                DetectionConstants.verboseLog(String(format: "[NiceShot] Pre-filter: rejecting %.2fs (transient SPEECH-LIKE)", time))
                return false
            }
            return true
        }

        // Step 3: dominant peak among pre-filter survivors. Operates on
        // `validatableCandidates` exclusively — see `findDominantAudioPeak`
        // doc comment for why.
        let candidatesForDominance = result.candidates.filter { c in
            c.accepted && validatableCandidates.contains(where: { abs($0 - c.time) < 0.05 })
        }
        let dominantTime = Self.findDominantAudioPeak(
            among: candidatesForDominance,
            multiplier: mode.values.dominanceMultiplier
        )

        // Build the non-dominant survivor list for motion validation.
        let transientSurvivors = validatableCandidates.filter { time in
            if let dt = dominantTime, abs(time - dt) < 0.5 { return false }
            return true
        }

        // Step 4: motion validation. V3.8 — skipped for short videos
        // that already have at least one (transient-survivor) audio peak.
        let isShortVideo = video.duration < DetectionConstants.shortVideoThresholdSeconds
        let runMotionValidation = effectiveSettings.motionValidationEnabled
            && !(isShortVideo && !transientSurvivors.isEmpty)

        var timestampsToExport: [Double]
        let motionConfirmedCount: Int
        if runMotionValidation && !transientSurvivors.isEmpty {
            progress(.validatingMotion)
            let validation = await motionValidator.validate(
                videoURL: video.localFileURL,
                videoDuration: video.duration,
                candidates: transientSurvivors,
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
            timestampsToExport = transientSurvivors
            // motionConfirmedCount only describes the validator's verdict.
            // When validation didn't run, it's "n/a" — we represent that
            // as the count we'd otherwise have validated. The PIPELINE
            // SUMMARY line below labels it as skipped.
            motionConfirmedCount = transientSurvivors.count
        }

        // Step 5: re-add the dominant peak (bypassed transient + motion).
        if let dt = dominantTime,
           !timestampsToExport.contains(where: { abs($0 - dt) < 0.5 }) {
            print(String(format: "[NiceShot] Auto-confirmed dominant audio peak at %.2fs (≥2× next strongest) — bypassed transient + motion", dt))
            timestampsToExport.append(dt)
            timestampsToExport.sort()
        }

        // V3.8 + V4.1 — loudest-peak fallback. Originally gated on
        // <15s ("user filmed one swing on purpose"); singleSwing mode
        // extends the same safety net to any duration so a 90s recording
        // of one quiet swing isn't silently dropped. rangeSession keeps
        // the short-only gate — long range videos with zero confirmed
        // swings genuinely have no swings, not a missed loudest peak.
        let canApplyLoudestFallback = mode.values.alwaysApplyLoudestFallback || isShortVideo
        var fallbackUsed = false
        if timestampsToExport.isEmpty,
           canApplyLoudestFallback,
           let loudest = result.loudestWindowTime {
            let why = mode.values.alwaysApplyLoudestFallback ? "singleSwing mode" : "short video"
            print(String(format: "[NiceShot] Fallback: using loudest peak at %.2fs (%@)", loudest, why))
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

        // V4.2 — singleSwing top-1 filter. The mode name promises one
        // clip; min-spacing alone doesn't deliver when three peaks are
        // spaced >2s apart and all pass motion. Final gate ranks the
        // survivors and keeps only the highest-confidence one:
        //   1. The auto-confirmed dominant peak, if one is in the set
        //      (≥2× next strongest — the algorithm's most confident verdict).
        //   2. Otherwise, the candidate with the highest audio energy
        //      ratio (loudest impact relative to its surrounding noise).
        // No-op when keepTopCandidateOnly is false (rangeSession), so
        // multi-swing behavior stays bit-identical.
        if mode.values.keepTopCandidateOnly && timestampsToExport.count > 1 {
            let originalCount = timestampsToExport.count
            let kept: Double
            if let dt = dominantTime,
               timestampsToExport.contains(where: { abs($0 - dt) < 0.5 }) {
                kept = dt
            } else {
                kept = timestampsToExport.max(by: { lhs, rhs in
                    Self.energyRatio(forTime: lhs, in: result.candidates)
                        < Self.energyRatio(forTime: rhs, in: result.candidates)
                }) ?? timestampsToExport[0]
            }
            let keptRatio = Self.energyRatio(forTime: kept, in: result.candidates)
            print(String(format: "[NiceShot] singleSwing top-1 filter: kept %.2fs (%.2fx audio ratio), dropped %d other candidates",
                         kept, keptRatio, originalCount - 1))
            timestampsToExport = [kept]
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

    /// V4.2 — Look up the energy ratio for a given timestamp from the
    /// candidates list, with a 50ms tolerance to absorb sub-window
    /// rounding. Returns 0 when no candidate matches (shouldn't happen
    /// for confirmed timestamps, but defensive against the loudest-peak
    /// fallback's window time which isn't in the candidate set).
    private static func energyRatio(forTime time: Double,
                                    in candidates: [ImpactCandidate]) -> Double {
        candidates.first(where: { abs($0.time - time) < 0.05 })?.energyRatio ?? 0
    }

    /// V3.10 / V3.12 — Find the audio peak whose energy ratio is at
    /// least `multiplier` times higher than every other candidate in
    /// the input set. Returns nil when there's no clear standout.
    /// Always logs the comparison so we can see what passed/failed.
    ///
    /// **Caller assumption.** `candidates` must already be the
    /// pre-filtered survivor set (transient drops + zero-prefix
    /// drops applied). Comparing against pre-filter-rejected peaks
    /// would compare against doomed candidates and let real impacts
    /// be blocked from auto-confirmation.
    private static func findDominantAudioPeak(among candidates: [ImpactCandidate],
                                              multiplier: Double) -> Double? {
        let sorted = candidates.sorted { $0.energyRatio > $1.energyRatio }

        let summary = sorted
            .map { String(format: "%.2fs:%.2fx", $0.time, $0.energyRatio) }
            .joined(separator: ", ")
        DetectionConstants.verboseLog("[NiceShot] Dominant-peak check | survivors=[\(summary)]")

        guard let strongest = sorted.first else {
            DetectionConstants.verboseLog("[NiceShot] Dominant-peak check: no survivors after pre-filter")
            return nil
        }
        if sorted.count == 1 {
            DetectionConstants.verboseLog(String(format: "[NiceShot] Dominant-peak check: single survivor at %.2fs (ratio %.2fx) — auto-confirmed",
                                                  strongest.time, strongest.energyRatio))
            return strongest.time
        }
        let next = sorted[1]
        let needed = multiplier * next.energyRatio
        let isDominant = strongest.energyRatio >= needed
        DetectionConstants.verboseLog(String(format: "[NiceShot] Dominant-peak check: strongest=%.2fs(%.2fx) next=%.2fs(%.2fx) need ≥%.2fx → %@",
                                              strongest.time, strongest.energyRatio,
                                              next.time, next.energyRatio, needed,
                                              isDominant ? "DOMINANT" : "not dominant"))
        return isDominant ? strongest.time : nil
    }

    /// V3.8 + V4.1 — Per-video derived settings.
    /// 1. Mode picks the base min-spacing (singleSwing 2.0s, rangeSession 6.0s).
    /// 2. V3.8 short-video clamp still applies on top: <30s videos get
    ///    `shortVideoMinSpacingSeconds` if it would tighten further.
    /// User-visible Settings/Debug values are unchanged; mode and the
    /// short-video clamp are pipeline-internal adjustments.
    ///
    // TODO: bug — min-spacing precision. Real candidate at 16.32s
    // (4.46×) was eliminated by 17.26s (4.88×) only 0.94s apart in
    // IMG_2253. The current 6.0s minimum may be too aggressive for
    // fast-paced range sessions where consecutive swings happen 1–3s
    // apart. Consider tying min-spacing to detected video tempo.
    //
    // V4.1 watch — singleSwing's 2.0s min-spacing is more permissive
    // than rangeSession's 6.0s. If a user overrides a video to
    // singleSwing mode and that video has two close-spaced legitimate
    // impacts (e.g. mishit + reset whack 3-5s apart), both will be
    // emitted. Acceptable for V1 — the mode is explicitly "lenient
    // toward catching" and the user has the chip to revert.
    private func adjustedSettings(for video: ImportedVideo,
                                  base: DetectionSettings,
                                  mode: DetectionMode) -> DetectionSettings {
        var s = base
        s.minimumSpacingSeconds = mode.values.minSpacingSeconds
        if video.duration < DetectionConstants.shortVideoSpacingThresholdSeconds {
            s.minimumSpacingSeconds = min(DetectionConstants.shortVideoMinSpacingSeconds, s.minimumSpacingSeconds)
        }
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

    /// V4.1 — persist the chosen DetectionMode on a video record. Called
    /// once on the first processing pass (auto-detected mode), and again
    /// whenever the user taps the override chip.
    private func updateVideoMode(id: UUID, mode: DetectionMode) {
        guard let idx = importedVideos.firstIndex(where: { $0.id == id }) else { return }
        importedVideos[idx].detectionMode = mode
        storage.saveVideos(importedVideos)
    }

    // MARK: - V4.1 — Per-video re-analyze (mode override)

    /// Re-run the pipeline on a single video with a specific
    /// DetectionMode, replacing its existing clips. Used by the
    /// ClipReviewView / SourceVideoPreviewView mode chip.
    ///
    /// Behavior:
    ///   1. Persist the new mode on the video record.
    ///   2. Delete the video's existing clip files + records.
    ///   3. Re-run `processVideo`, which now sees the persisted mode
    ///      and runs the full pipeline under it.
    ///
    /// Audio decode + RMS dominate the cost (~few seconds even on long
    /// videos thanks to vDSP). The rest of the batch is unaffected.
    /// Caller is expected to disable the chip while this is in flight.
    func reanalyzeVideo(_ video: ImportedVideo, mode: DetectionMode) async {
        errorMessage = nil

        updateVideoMode(id: video.id, mode: mode)

        let oldClips = clips.filter { $0.sourceVideoId == video.id }
        for clip in oldClips {
            FileManagerHelpers.deleteFile(atRelativePath: clip.relativePath)
            if let t = clip.thumbnailRelativePath {
                FileManagerHelpers.deleteFile(atRelativePath: t)
            }
        }
        clips.removeAll { $0.sourceVideoId == video.id }
        storage.saveClips(clips)

        updateVideoStatus(id: video.id, status: .pending, errorMessage: nil)

        // Refetch — the local `video` snapshot doesn't have the
        // freshly-persisted mode. processVideo reads detectionMode off
        // the record, so it must be the updated copy.
        guard let freshVideo = importedVideos.first(where: { $0.id == video.id }) else { return }

        let outcome = await processVideo(freshVideo) { newStatus in
            self.updateVideoStatus(id: video.id, status: newStatus, errorMessage: nil)
        }

        switch outcome {
        case .success:
            updateVideoStatus(id: video.id, status: .completed, errorMessage: nil)
        case .noShots:
            updateVideoStatus(id: video.id, status: .noShotsFound, errorMessage: nil)
        case .noAudio:
            updateVideoStatus(id: video.id, status: .noAudio, errorMessage: "No audio track")
        case .failure(let err):
            updateVideoStatus(id: video.id, status: .failed, errorMessage: err.localizedDescription)
            errorMessage = err.localizedDescription
        }
    }
}
