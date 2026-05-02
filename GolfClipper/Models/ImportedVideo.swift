// ImportedVideo.swift
// Represents a video the user imported from their Photos library.
// We persist this to local JSON so the app can remember it across launches.

import Foundation

struct ImportedVideo: Identifiable, Codable, Hashable {
    let id: UUID
    var originalFilename: String
    // Stored as a relative path under the app's Documents directory.
    // We resolve to a full URL when needed. This makes the app robust
    // to the Documents path changing between launches (it can on iOS).
    var relativePath: String
    var importedAt: Date
    var duration: Double // seconds

    var localFileURL: URL {
        FileManagerHelpers.documentsDirectory.appendingPathComponent(relativePath)
    }

    init(id: UUID = UUID(),
         originalFilename: String,
         relativePath: String,
         importedAt: Date = Date(),
         duration: Double) {
        self.id = id
        self.originalFilename = originalFilename
        self.relativePath = relativePath
        self.importedAt = importedAt
        self.duration = duration
    }
}
