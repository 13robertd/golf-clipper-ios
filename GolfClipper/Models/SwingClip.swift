// SwingClip.swift
// Represents a single golf-swing clip created from the imported video.
// Clips can be auto-generated from audio detection OR manually created.

import Foundation

struct SwingClip: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceVideoId: UUID

    // Stored as a relative path in Documents (see ImportedVideo).
    var relativePath: String
    var thumbnailRelativePath: String?

    var createdAt: Date
    var duration: Double      // seconds
    var impactTimestamp: Double // seconds into source video
    var startTime: Double     // seconds into source video
    var endTime: Double       // seconds into source video

    var isManual: Bool
    var isSavedToPhotos: Bool

    var localFileURL: URL {
        FileManagerHelpers.documentsDirectory.appendingPathComponent(relativePath)
    }

    var thumbnailURL: URL? {
        guard let thumb = thumbnailRelativePath else { return nil }
        return FileManagerHelpers.documentsDirectory.appendingPathComponent(thumb)
    }

    init(id: UUID = UUID(),
         sourceVideoId: UUID,
         relativePath: String,
         thumbnailRelativePath: String? = nil,
         createdAt: Date = Date(),
         duration: Double,
         impactTimestamp: Double,
         startTime: Double,
         endTime: Double,
         isManual: Bool = false,
         isSavedToPhotos: Bool = false) {
        self.id = id
        self.sourceVideoId = sourceVideoId
        self.relativePath = relativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.createdAt = createdAt
        self.duration = duration
        self.impactTimestamp = impactTimestamp
        self.startTime = startTime
        self.endTime = endTime
        self.isManual = isManual
        self.isSavedToPhotos = isSavedToPhotos
    }
}
