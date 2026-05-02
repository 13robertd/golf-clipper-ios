// FileManagerHelpers.swift
// Tiny helpers for working with the app's Documents directory.
// We keep all imported videos, clips, and thumbnails inside Documents
// so they persist across launches and are easy to find/delete.

import Foundation

enum FileManagerHelpers {

    // The root directory where we store everything for this app.
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // Sub-folders we use. Created on demand.
    static let videosFolderName = "ImportedVideos"
    static let clipsFolderName = "Clips"
    static let thumbnailsFolderName = "Thumbnails"

    static var videosFolderURL: URL {
        ensureFolder(named: videosFolderName)
    }

    static var clipsFolderURL: URL {
        ensureFolder(named: clipsFolderName)
    }

    static var thumbnailsFolderURL: URL {
        ensureFolder(named: thumbnailsFolderName)
    }

    @discardableResult
    static func ensureFolder(named name: String) -> URL {
        let url = documentsDirectory.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url,
                                                     withIntermediateDirectories: true)
        }
        return url
    }

    // Convert a full URL inside Documents back to a relative path so we can
    // store it in JSON without breaking if the Documents path changes.
    static func relativePath(for url: URL) -> String {
        let docs = documentsDirectory.path
        if url.path.hasPrefix(docs) {
            return String(url.path.dropFirst(docs.count + 1)) // drop trailing /
        }
        return url.lastPathComponent
    }

    // Delete a file at a relative-Documents path. Silent on failure.
    static func deleteFile(atRelativePath relativePath: String) {
        let url = documentsDirectory.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }
}
