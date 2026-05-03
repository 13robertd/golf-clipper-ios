//
//  ShareViewController.swift
//  NiceShotShare
//
//  V6.2 — Filename-only handoff.
//
//  The extension does NO Photos query and NO file copy. It writes a
//  ~100-byte JSON descriptor naming the suggestedName of each video
//  attachment and dismisses. The main app — which runs on a background
//  queue and already has Photos authorization — resolves the asset
//  during its analysis sheet, where there's already a progress UI.
//
//  Why we moved the lookup out: V6.1 ran the lookup here, which forced
//  a per-asset fetch of PHAssetOriginalMetadataProperties on the main
//  queue (Apple logs a perf warning for exactly this). With a busy
//  library it took >5s per share. The new path is sub-100ms regardless
//  of library size.
//

import UIKit
import Social
import UniformTypeIdentifiers
import UserNotifications

/// `@objc(ShareViewController)` — forces the Objective-C runtime to
/// register this class under the unqualified name the storyboard's
/// `customClass="ShareViewController"` lookup uses. Without it, Swift
/// classes are registered under the mangled name (`NiceShotShare.ShareViewController`)
/// and Interface Builder's class lookup can fail silently — iOS then
/// instantiates the base `SLComposeServiceViewController`, our `viewDidLoad`
/// and `didSelectPost` overrides never run, and the share appears to
/// succeed but no descriptors are written.
@objc(ShareViewController)
class ShareViewController: SLComposeServiceViewController {

    /// Must match `SharedContainerImporter.groupID` in the main app.
    private let appGroupID = "group.com.robertdeng.golfclipper"
    private let pendingDirectoryName = "pending"

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Nice Shot"
        self.placeholder = "Tap Post to send to Nice Shot"
    }

    override func isContentValid() -> Bool {
        // Activation rules already enforce a video attachment is present.
        return true
    }

    override func didSelectPost() {
        let videoCount = writeDescriptors()
        if videoCount > 0 {
            scheduleOpenAppNotification(videoCount: videoCount)
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    override func configurationItems() -> [Any]! {
        return []
    }

    // MARK: - Descriptor writing

    /// Writes one JSON descriptor per video attachment. Synchronous
    /// because all we're doing is filesystem-level small-file writes —
    /// no I/O blocking, no Photos calls, no network. Returns how many
    /// videos we actually wrote a descriptor for, so the caller can
    /// suppress the open-app notification if the share somehow contained
    /// no video attachments at all.
    @discardableResult
    private func writeDescriptors() -> Int {
        guard let pendingDir = ensurePendingDirectory() else {
            NSLog("[NiceShotShare] App Group container unavailable for \(appGroupID)")
            return 0
        }

        var count = 0
        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in inputItems {
            for provider in (item.attachments ?? []) {
                guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
                    continue
                }
                let suggestedName = provider.suggestedName ?? ""
                writeFilenameDescriptor(filename: suggestedName, pendingDir: pendingDir)
                count += 1
            }
        }
        return count
    }

    private func writeFilenameDescriptor(filename: String, pendingDir: URL) {
        let payload: [String: Any] = [
            "kind": "filename",
            "filename": filename,
            "writtenAt": ISO8601DateFormatter().string(from: Date())
        ]
        let descriptorURL = pendingDir.appendingPathComponent("\(UUID().uuidString).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            try data.write(to: descriptorURL, options: .atomic)
        } catch {
            NSLog("[NiceShotShare] Descriptor write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Open-app notification (V6.3)

    /// Posts a single local notification telling the user "Nice Shot is
    /// ready to clip your video — tap to open." Apple does not allow a
    /// share extension to launch its containing app directly without
    /// using the responder-chain trick, which is App Store-risky. This
    /// is the App-Store-safe substitute: when the user taps the banner,
    /// iOS foregrounds Nice Shot, the existing scenePhase observer in
    /// GolfClipperApp fires, and the import + analysis kicks off
    /// automatically.
    ///
    /// We use a single fixed identifier so back-to-back shares replace
    /// the previous notification rather than piling up — the user only
    /// needs ONE banner to know the app has work waiting.
    private func scheduleOpenAppNotification(videoCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Nice Shot"
        content.body = videoCount == 1
            ? "Tap to clip your video"
            : "Tap to clip your \(videoCount) videos"
        // No sound — the banner is purely a "you can tap to open" prompt,
        // not an alert that needs urgency.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "com.robertdeng.golfclipper.share-pending",
            content: content,
            trigger: nil // fire immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[NiceShotShare] Notification scheduling failed: \(error.localizedDescription)")
            }
        }
    }

    private func ensurePendingDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        let pending = container.appendingPathComponent(pendingDirectoryName,
                                                       isDirectory: true)
        if !FileManager.default.fileExists(atPath: pending.path) {
            try? FileManager.default.createDirectory(at: pending,
                                                     withIntermediateDirectories: true)
        }
        return pending
    }
}
