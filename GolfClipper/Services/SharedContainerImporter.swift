// SharedContainerImporter.swift
// V6 — App Group ↔ main-app handoff.
// V6.1 — Descriptor-based handoff. The Share Extension no longer copies
// the full video file into the App Group (which is slow, especially for
// iCloud-only videos). Instead it writes a tiny JSON descriptor naming
// the PHAsset identifier; the main app fetches the actual video from
// Photos via the existing `VideoImportService.importVideo(fromAssetIdentifier:)`
// path. Sharing dismisses in 1–2 seconds; the heavy file work happens
// in the main app's analysis flow where there's already a progress UI.
//
// We still support a "file" descriptor kind for the fallback case where
// the extension couldn't resolve an asset identifier (Photos access not
// granted, or the suggested filename didn't match anything in the
// library). And we tolerate raw video files dropped directly into
// pending/ from any older build of the extension.
//
// The group ID is duplicated here and in NiceShotShare/ShareViewController.swift
// (only as a string literal — five lines of code) because sharing a
// Swift file across an extension and its containing app requires the
// file to be a member of both targets, which means more pbxproj
// surgery. For one constant + a few helpers it's not worth it.

import Foundation

// MARK: - Descriptor model

/// A pending import the Share Extension queued for the main app to
/// pick up. V6.2 added the `.filename(_)` case — the cheapest possible
/// extension-side write. The main app does the Photos lookup on a
/// background queue, behind the analysis sheet that's already showing
/// progress.
struct PendingImportDescriptor: Equatable {
    enum Kind: Equatable {
        /// V6.2 default — extension only knows the suggestedName from
        /// NSItemProvider; main app finds the matching PHAsset.
        case filename(String)
        /// V6.1 fast path — extension already resolved the PHAsset
        /// identifier. Kept for backward compat with any pending
        /// descriptors written by an older build.
        case asset(identifier: String)
        /// V6 fallback — extension copied the actual video file into
        /// the App Group container. Kept for backward compat / future
        /// fallback need.
        case file(url: URL)
    }
    let descriptorURL: URL?  // path to the .json descriptor (nil for legacy raw-file imports)
    let kind: Kind
    let filename: String     // user-recognizable name; only for diagnostics
}

// MARK: - Wire format

/// On-disk JSON shape. Keeping this private + small means future
/// schema bumps need only forward-compat handling here, not in callers.
private struct DescriptorPayload: Codable {
    /// "asset" or "file"
    let kind: String
    let assetIdentifier: String?
    let relativePath: String?
    let filename: String
    let writtenAt: Date
}

// MARK: - Helper

enum SharedContainerImporter {

    /// Must match the App Group ID configured in both targets'
    /// .entitlements files.
    static let groupID = "group.com.robertdeng.golfclipper"

    /// Subdirectory inside the shared container where the extension drops
    /// descriptors (and, in the fallback case, copied video files). Top-
    /// level so it's easy to inspect from Xcode's container browser.
    static let pendingDirectoryName = "pending"

    /// Subdirectory inside `pending/` for fallback inline files. Using a
    /// subdirectory keeps the descriptor scan (which lists *.json) clean.
    static let inlineFilesSubdirectoryName = "files"

    /// Root of the App Group container, or nil if the entitlement isn't
    /// active (which would be a misconfiguration — log and bail).
    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        )
    }

    /// Pending-imports directory, created on demand.
    static var pendingDirectoryURL: URL? {
        guard let container = containerURL else { return nil }
        let url = container.appendingPathComponent(pendingDirectoryName,
                                                   isDirectory: true)
        ensureDirectory(url)
        return url
    }

    /// Subdirectory for fallback inline video files.
    static var inlineFilesDirectoryURL: URL? {
        guard let pending = pendingDirectoryURL else { return nil }
        let url = pending.appendingPathComponent(inlineFilesSubdirectoryName,
                                                 isDirectory: true)
        ensureDirectory(url)
        return url
    }

    private static func ensureDirectory(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url,
                                                     withIntermediateDirectories: true)
        }
    }

    /// Returns descriptors for everything pending in the shared container,
    /// sorted by mod-time so we process them in the order they were
    /// shared. Tolerant of malformed JSON (bad files are skipped, not
    /// crashed on) and of raw video files dropped directly into pending/
    /// by the V6 (pre-V6.1) extension.
    static func pendingDescriptors() -> [PendingImportDescriptor] {
        guard let dir = pendingDirectoryURL else { return [] }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

        var descriptors: [PendingImportDescriptor] = []
        for url in urls {
            // Skip the inline-files subdirectory; we surface those via
            // their owning JSON descriptor, not directly.
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { continue }

            let ext = url.pathExtension.lowercased()
            if ext == "json" {
                if let d = parseDescriptor(at: url) {
                    descriptors.append(d)
                }
            } else if videoExtensions.contains(ext) {
                // V6 legacy: raw video file dropped directly in pending/.
                // Treat it as a "file" descriptor with no JSON to clean up.
                descriptors.append(PendingImportDescriptor(
                    descriptorURL: nil,
                    kind: .file(url: url),
                    filename: stripUUIDPrefix(url.lastPathComponent)
                ))
            }
        }

        return descriptors.sorted { lhs, rhs in
            let l = mtime(lhs)
            let r = mtime(rhs)
            return l < r
        }
    }

    /// Removes the descriptor (and any inline file it references) from
    /// the App Group. Called by AppState after a successful import OR
    /// after an unrecoverable failure, so a corrupt entry can't loop.
    static func cleanup(_ descriptor: PendingImportDescriptor) {
        if let descURL = descriptor.descriptorURL {
            try? FileManager.default.removeItem(at: descURL)
        }
        if case .file(let url) = descriptor.kind {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Internals

    private static func parseDescriptor(at url: URL) -> PendingImportDescriptor? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(DescriptorPayload.self, from: data) else {
            return nil
        }
        switch payload.kind {
        case "filename":
            return PendingImportDescriptor(
                descriptorURL: url,
                kind: .filename(payload.filename),
                filename: payload.filename
            )
        case "asset":
            guard let id = payload.assetIdentifier, !id.isEmpty else { return nil }
            return PendingImportDescriptor(
                descriptorURL: url,
                kind: .asset(identifier: id),
                filename: payload.filename
            )
        case "file":
            guard let rel = payload.relativePath,
                  let pendingDir = pendingDirectoryURL else { return nil }
            let fileURL = pendingDir.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return PendingImportDescriptor(
                descriptorURL: url,
                kind: .file(url: fileURL),
                filename: payload.filename
            )
        default:
            return nil
        }
    }

    private static func mtime(_ descriptor: PendingImportDescriptor) -> Date {
        let url = descriptor.descriptorURL ?? {
            if case .file(let u) = descriptor.kind { return u }
            return URL(fileURLWithPath: "/")
        }()
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                       .contentModificationDate) ?? .distantPast
    }

    /// Pattern from the V6 extension: "<UUID>_<original>". Returns the
    /// original portion if it matches, else the whole string.
    private static func stripUUIDPrefix(_ name: String) -> String {
        if let underscoreIdx = name.firstIndex(of: "_") {
            return String(name[name.index(after: underscoreIdx)...])
        }
        return name
    }
}
