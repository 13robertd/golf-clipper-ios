// AppState.swift
// Single ObservableObject that holds everything the UI needs. Views read
// from it and call its methods to make things happen. Keeping it in one
// place keeps the V1 architecture easy to follow.

import Foundation
import SwiftUI
import PhotosUI

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var importedVideo: ImportedVideo?
    @Published var clips: [SwingClip] = []
    @Published var settings: DetectionSettings = .default

    @Published var analysis: AnalysisState = .idle
    @Published var lastDetectedTimestamps: [Double] = []
    /// Scored detection candidates from the most recent analysis. Used by
    /// SettingsDebugView to show why each loud event was accepted/rejected.
    @Published var lastCandidates: [ImpactCandidate] = []

    // Used by views to surface errors (alerts).
    @Published var errorMessage: String?

    // MARK: - Services

    private let storage = LocalStorageService.shared
    private let importer = VideoImportService()
    private let detector = AudioImpactDetector()
    private let exporter = ClipExportService()
    private let saver = PhotosSaveService()
    private let thumbnailer = ThumbnailGenerator()

    // MARK: - Init

    init() {
        // Restore state on launch.
        self.importedVideo = storage.loadVideo()
        self.clips = storage.loadClips().sorted { $0.impactTimestamp < $1.impactTimestamp }
        self.settings = storage.loadSettings()
    }

    // MARK: - Settings

    func updateSettings(_ new: DetectionSettings) {
        self.settings = new
        storage.saveSettings(new)
    }

    // MARK: - Import

    /// User picked a video — copy it locally, then trigger analysis.
    func importPickedItem(_ item: PhotosPickerItem) async {
        analysis = .importing
        errorMessage = nil
        do {
            let video = try await importer.importVideo(from: item)
            // New import wipes old clips so the review list reflects the new video.
            removeAllClipFiles()
            self.clips = []
            self.lastDetectedTimestamps = []
            self.lastCandidates = []
            self.importedVideo = video
            storage.saveVideo(video)
            storage.saveClips([])

            // Confirm there is audio. If not, we tell user to use Manual Clip.
            let hasAudio = await importer.videoHasAudioTrack(video)
            if !hasAudio {
                analysis = .failed("This video has no audio track. Use Manual Clip.")
                errorMessage = "This video has no audio track. Use Manual Clip."
                return
            }

            await analyzeAndCreateClips()
        } catch {
            analysis = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Analyze + clip

    func analyzeAndCreateClips() async {
        guard let video = importedVideo else { return }
        errorMessage = nil
        analysis = .analyzing(progress: 0)

        do {
            let result = try await detector.detectImpacts(in: video,
                                                          settings: settings) { [weak self] frac in
                Task { @MainActor in
                    self?.analysis = .analyzing(progress: frac)
                }
            }
            self.lastDetectedTimestamps = result.impactTimestamps
            self.lastCandidates = result.candidates

            if result.impactTimestamps.isEmpty {
                analysis = .failed("No swings found. Try lowering sensitivity or use Manual Clip.")
                errorMessage = "No swings found. Try lowering sensitivity or use Manual Clip."
                return
            }

            analysis = .creatingClips(done: 0, total: result.impactTimestamps.count)

            // Wipe any existing clips before we generate a new set.
            removeAllClipFiles()
            self.clips = []

            let newClips = await exporter.exportClips(
                from: video,
                impactTimes: result.impactTimestamps,
                settings: settings,
                isManual: false
            ) { [weak self] done, total in
                Task { @MainActor in
                    self?.analysis = .creatingClips(done: done, total: total)
                }
            }

            // Generate thumbnails for each clip.
            var withThumbs: [SwingClip] = []
            for var clip in newClips {
                if let thumbURL = await thumbnailer.generateThumbnail(for: clip) {
                    clip.thumbnailRelativePath = FileManagerHelpers.relativePath(for: thumbURL)
                }
                withThumbs.append(clip)
            }

            self.clips = withThumbs.sorted { $0.impactTimestamp < $1.impactTimestamp }
            storage.saveClips(self.clips)
            analysis = .completed(clipCount: self.clips.count)
        } catch {
            analysis = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Manual clip

    /// Build a single manual clip around `time`.
    func createManualClip(atTime time: Double) async {
        guard let video = importedVideo else { return }
        errorMessage = nil
        do {
            var clip = try await exporter.exportClip(from: video,
                                                     impactTime: time,
                                                     settings: settings,
                                                     isManual: true)
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

    func deleteAllClipsAndVideo() {
        for clip in clips {
            FileManagerHelpers.deleteFile(atRelativePath: clip.relativePath)
            if let t = clip.thumbnailRelativePath {
                FileManagerHelpers.deleteFile(atRelativePath: t)
            }
        }
        clips = []
        if let v = importedVideo {
            FileManagerHelpers.deleteFile(atRelativePath: v.relativePath)
        }
        importedVideo = nil
        lastDetectedTimestamps = []
        lastCandidates = []
        analysis = .idle
        storage.saveClips([])
        storage.saveVideo(nil)
    }

    // MARK: - Save to Photos

    func saveClipToPhotos(_ clip: SwingClip) async {
        do {
            try await saver.saveVideoToPhotos(at: clip.localFileURL)
            // Mark saved.
            if let idx = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[idx].isSavedToPhotos = true
                storage.saveClips(clips)
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

    // MARK: - Helpers

    private func removeAllClipFiles() {
        for clip in clips {
            FileManagerHelpers.deleteFile(atRelativePath: clip.relativePath)
            if let thumb = clip.thumbnailRelativePath {
                FileManagerHelpers.deleteFile(atRelativePath: thumb)
            }
        }
    }
}

// MARK: - AnalysisState

enum AnalysisState: Equatable {
    case idle
    case importing
    case analyzing(progress: Double)
    case creatingClips(done: Int, total: Int)
    case completed(clipCount: Int)
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:                return ""
        case .importing:           return "Importing video…"
        case .analyzing(let p):    return "Analyzing audio… \(Int(p * 100))%"
        case .creatingClips(let d, let t): return "Creating clips… \(d)/\(t)"
        case .completed(let n):    return "Done — \(n) swings detected"
        case .failed(let msg):     return msg
        }
    }

    var isWorking: Bool {
        switch self {
        case .importing, .analyzing, .creatingClips: return true
        default: return false
        }
    }
}
