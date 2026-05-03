// LocalStorageService.swift
// Tiny JSON-on-disk persistence layer. Avoids SwiftData complexity for V1.
//
// V1.5 changes:
//  - The single `imported_video.json` becomes a list at `imported_videos.json`.
//  - On first launch after upgrade, we migrate the old single record into
//    a one-element array so the user doesn't lose their imported video.
//
// Files in Documents:
//   - imported_videos.json   (array of ImportedVideo metadata)
//   - clips.json             (array of SwingClip metadata)
//   - settings.json          (DetectionSettings)

import Foundation

final class LocalStorageService {
    static let shared = LocalStorageService()

    // Current filenames (V1.5+).
    private let videosFilename = "imported_videos.json"
    private let clipsFilename = "clips.json"
    private let settingsFilename = "settings.json"

    // Legacy filename (V1) — read on first launch then deleted.
    private let legacyVideoFilename = "imported_video.json"

    private var videosURL:        URL { docs(videosFilename) }
    private var clipsURL:         URL { docs(clipsFilename) }
    private var settingsURL:      URL { docs(settingsFilename) }
    private var legacyVideoURL:   URL { docs(legacyVideoFilename) }

    private func docs(_ name: String) -> URL {
        FileManagerHelpers.documentsDirectory.appendingPathComponent(name)
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - ImportedVideos

    /// Load the list of imported videos. If the new file is missing but the
    /// legacy V1 single-video file exists, migrate it into a one-element list.
    func loadVideos() -> [ImportedVideo] {
        if let data = try? Data(contentsOf: videosURL),
           let videos = try? decoder.decode([ImportedVideo].self, from: data) {
            return videos
        }
        // Legacy migration: V1 stored a single video.
        if let data = try? Data(contentsOf: legacyVideoURL),
           let video = try? decoder.decode(ImportedVideo.self, from: data) {
            return [video]
        }
        return []
    }

    func saveVideos(_ videos: [ImportedVideo]) {
        if let data = try? encoder.encode(videos) {
            try? data.write(to: videosURL, options: .atomic)
        }
        // Best-effort: clean up the legacy file once we've taken ownership.
        if FileManager.default.fileExists(atPath: legacyVideoURL.path) {
            try? FileManager.default.removeItem(at: legacyVideoURL)
        }
    }

    // MARK: - Clips

    func loadClips() -> [SwingClip] {
        guard let data = try? Data(contentsOf: clipsURL),
              let clips = try? decoder.decode([SwingClip].self, from: data) else {
            return []
        }
        return clips
    }

    func saveClips(_ clips: [SwingClip]) {
        if let data = try? encoder.encode(clips) {
            try? data.write(to: clipsURL, options: .atomic)
        }
    }

    // MARK: - DetectionSettings

    func loadSettings() -> DetectionSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? decoder.decode(DetectionSettings.self, from: data) else {
            return .default
        }
        return s
    }

    func saveSettings(_ settings: DetectionSettings) {
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }
}
