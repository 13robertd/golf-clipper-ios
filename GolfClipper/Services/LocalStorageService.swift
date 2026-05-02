// LocalStorageService.swift
// Tiny JSON-on-disk persistence layer. Avoids SwiftData complexity for V1.
// We store three small files in Documents:
//   - imported_video.json   (the most-recent imported video metadata)
//   - clips.json            (array of SwingClip metadata)
//   - settings.json         (DetectionSettings)

import Foundation

final class LocalStorageService {
    static let shared = LocalStorageService()

    private let videoFilename = "imported_video.json"
    private let clipsFilename = "clips.json"
    private let settingsFilename = "settings.json"

    private var videoURL: URL { FileManagerHelpers.documentsDirectory.appendingPathComponent(videoFilename) }
    private var clipsURL: URL { FileManagerHelpers.documentsDirectory.appendingPathComponent(clipsFilename) }
    private var settingsURL: URL { FileManagerHelpers.documentsDirectory.appendingPathComponent(settingsFilename) }

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

    // MARK: - ImportedVideo

    func loadVideo() -> ImportedVideo? {
        guard let data = try? Data(contentsOf: videoURL) else { return nil }
        return try? decoder.decode(ImportedVideo.self, from: data)
    }

    func saveVideo(_ video: ImportedVideo?) {
        guard let video else {
            try? FileManager.default.removeItem(at: videoURL)
            return
        }
        if let data = try? encoder.encode(video) {
            try? data.write(to: videoURL, options: .atomic)
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
