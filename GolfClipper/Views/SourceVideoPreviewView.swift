// SourceVideoPreviewView.swift
// V5 — Tappable source-video preview opened from the Home screen list.
// Shows the original imported video, its metadata, and the actions
// available for it. Presented as a sheet with its own NavigationStack
// so swipe-down dismisses (per spec) and "Create Manual Clip" can push
// onto the stack without nested sheets.
//
// Re-analyze is intentionally absent — there is no per-video reanalyze
// in AppState (only `reanalyzeAllVideos`), and the spec says only show
// the button "if existing functionality supports it."

import SwiftUI
import AVKit

struct SourceVideoPreviewView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let video: ImportedVideo

    /// Caller is notified when the user taps "View Clips from This Video"
    /// so the parent can sheet-handoff to ClipReviewView with this id as
    /// the deep-link scroll target. We dismiss ourselves immediately;
    /// parent handles the open in our `.onDismiss`.
    let onViewClipsTapped: (UUID) -> Void

    @State private var player: AVPlayer?
    @State private var isDeletingOriginal = false

    /// V4.1 — chip / re-analyze state. Mirrors ClipReviewView's pattern.
    @State private var isReanalyzing = false
    @State private var modeSwitchPromptVisible = false

    // V4.3 — DEBUG-only pose detection spike state.
    #if DEBUG
    @State private var isRunningPoseSpike = false
    @State private var poseSpikeShareURLs: [URL] = []
    @State private var poseSpikeSharePresented = false
    #endif

    /// Whether the local imported file actually exists on disk. If the
    /// user manually deleted it (or the sandbox path drifted), we still
    /// show the metadata but replace the player with an explanation.
    private var hasPlayableLocalCopy: Bool {
        FileManager.default.fileExists(atPath: video.localFileURL.path)
    }

    private var clipCount: Int {
        app.clips.filter { $0.sourceVideoId == video.id }.count
    }

    /// V4.1 — Live mode for the displayed record. Prefers the persisted
    /// value; falls back to auto-detect for legacy records (which
    /// shouldn't exist post-V4.1 first run, but defends against it).
    private var currentMode: DetectionMode {
        currentVideo.detectionMode ?? DetectionMode.autoDetect(forDuration: video.duration)
    }

    /// V4.1 — refetch the current record so the chip reflects mode
    /// updates from re-analyze. The view's `video` is a snapshot at
    /// open time.
    private var currentVideo: ImportedVideo {
        app.importedVideos.first(where: { $0.id == video.id }) ?? video
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    playerSection
                    metadataSection
                    actionsSection
                }
                .padding()
            }
            .navigationTitle(video.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if hasPlayableLocalCopy {
                    player = AVPlayer(url: video.localFileURL)
                }
            }
            .onDisappear { player?.pause() }
        }
    }

    // MARK: - Player

    @ViewBuilder
    private var playerSection: some View {
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            // V5 — when the local copy is gone we keep the layout shape
            // (16:9 placeholder) so the rest of the metadata still looks
            // anchored, instead of collapsing into a tight stack.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "film.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("Source video unavailable.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                )
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(TimeFormatter.mmss(video.duration))
                    .font(.subheadline.monospacedDigit())
                Text("·")
                Text("\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                    .font(.subheadline)
                // V4.1 — Mode chip lives in the metadata row alongside
                // duration and clip count. Crucial entry point for the
                // no-clips case: ClipReviewView's section header only
                // appears for videos that produced clips; this screen
                // is reachable from HomeView for any imported video.
                ModeChip(
                    mode: currentMode,
                    isReanalyzing: isReanalyzing,
                    onTap: { modeSwitchPromptVisible = true }
                )
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: photosStatusIcon)
                    .foregroundStyle(photosStatusColor)
                Text(photosStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Switch to \(currentMode.opposite.displayName)?",
            isPresented: $modeSwitchPromptVisible,
            titleVisibility: .visible
        ) {
            Button("Switch and Re-analyze", role: .destructive) {
                Task { await runReanalyze(mode: currentMode.opposite) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(currentMode.opposite.summary) Clips will be regenerated.")
        }
    }

    /// V4.1 — One-tap re-analyze for the displayed video.
    /// V4.2 — minimum 600ms spinner so the user perceives the work
    /// (short-video reruns can finish faster than the eye can register
    /// the state change otherwise).
    private func runReanalyze(mode: DetectionMode) async {
        isReanalyzing = true
        let started = Date()
        print("[NiceShot] Reanalyze: starting for \(currentVideo.displayName) in \(mode.rawValue) mode")

        await app.reanalyzeVideo(currentVideo, mode: mode)

        let elapsedMs = Date().timeIntervalSince(started) * 1000
        let producedClipCount = app.clips.filter { $0.sourceVideoId == currentVideo.id }.count
        print(String(format: "[NiceShot] Reanalyze: completed in %.0fms, produced %d clips",
                     elapsedMs, producedClipCount))

        let minVisibleMs: Double = 600
        if elapsedMs < minVisibleMs {
            let remainingNs = UInt64((minVisibleMs - elapsedMs) * 1_000_000)
            try? await Task.sleep(nanoseconds: remainingNs)
        }

        isReanalyzing = false
    }

    private var photosStatusText: String {
        if video.wasOriginalDeletedFromPhotos {
            return "Original deleted from Photos"
        }
        if video.originalAssetIdentifier != nil {
            return "Original in Photos"
        }
        return "Local copy only"
    }

    private var photosStatusIcon: String {
        if video.wasOriginalDeletedFromPhotos { return "trash" }
        if video.originalAssetIdentifier != nil { return "photo.on.rectangle" }
        return "internaldrive"
    }

    private var photosStatusColor: Color {
        if video.wasOriginalDeletedFromPhotos { return .secondary }
        if video.originalAssetIdentifier != nil { return .green }
        return .secondary
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 12) {
            if clipCount > 0 {
                Button {
                    let id = video.id
                    dismiss()
                    onViewClipsTapped(id)
                } label: {
                    Label("View Clips from This Video", systemImage: "rectangle.stack.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else if currentVideo.processingStatus.isTerminal {
                // V4.1 — Inline empty-state CTA. When detection already
                // ran and produced no clips, surface a one-tap path to
                // try the other mode. This is the recovery affordance
                // for users whose video was misclassified by auto-detect
                // (e.g. a 60s recording of one quiet swing).
                Button {
                    Task { await runReanalyze(mode: currentMode.opposite) }
                } label: {
                    if isReanalyzing {
                        ProgressView()
                    } else {
                        Label("Try \(currentMode.opposite.displayName) mode",
                              systemImage: currentMode.opposite.symbolName)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(isReanalyzing)
            }

            // V5 — Manual Clip pushes onto our own NavigationStack, so the
            // sheet stays mounted and dismissing returns here, not Home.
            if hasPlayableLocalCopy {
                NavigationLink {
                    ManualClipView(video: video)
                } label: {
                    Label("Create Manual Clip", systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            deleteOriginalControl
                .padding(.top, 4)

            #if DEBUG
            poseSpikeButton
                .padding(.top, 4)
            #endif
        }
    }

    #if DEBUG
    /// V4.3 — Research-only "Run Pose Spike" trigger. Runs Apple Vision
    /// pose detection on this video and shares the four annotated JPEG
    /// stills via the system share sheet so the user can save them to
    /// Photos / Files / AirDrop for ground-truth inspection. Never
    /// shipped — gated behind `#if DEBUG` so RELEASE builds drop it.
    private var poseSpikeButton: some View {
        Button {
            Task { await runPoseSpike() }
        } label: {
            if isRunningPoseSpike {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Label("Run Pose Spike (DEBUG)", systemImage: "figure.golf")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground))
        .foregroundStyle(.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .disabled(isRunningPoseSpike)
        .sheet(isPresented: $poseSpikeSharePresented) {
            PoseSpikeShareSheet(items: poseSpikeShareURLs)
        }
    }

    /// V4.3 iteration 2: loop through every clip for this source video,
    /// run the pose analyzer on each one (operating on the EXPORTED CLIP
    /// rather than the source video), and accumulate the per-clip JPEGs
    /// into a single share sheet at the end. Per-clip output lives in
    /// `Documents/pose_spike/<source filename>/clip_<impactSec>s_<UUID prefix>/`.
    /// The UUID prefix prevents two clips with the same rounded impact
    /// timestamp from overwriting each other's stills.
    private func runPoseSpike() async {
        isRunningPoseSpike = true
        defer { isRunningPoseSpike = false }

        let clips = app.clips
            .filter { $0.sourceVideoId == video.id }
            .sorted { $0.impactTimestamp < $1.impactTimestamp }

        guard !clips.isEmpty else {
            print("[NiceShot] PoseSpike: no clips to analyze for \(video.displayName)")
            return
        }

        print("[NiceShot] PoseSpike: starting batch of \(clips.count) clip(s) for \(video.displayName)")

        let sourceDir = FileManagerHelpers.poseSpikeFolderURL(forVideoFilename: video.originalFilename)
        var allURLs: [URL] = []

        for clip in clips {
            let uuidPrefix = String(clip.id.uuidString.prefix(8))
            let clipFolderName = String(format: "clip_%.2fs_%@", clip.impactTimestamp, uuidPrefix)
            let clipDir = sourceDir.appendingPathComponent(clipFolderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)

            let impactInClip = clip.impactTimestamp - clip.startTime
            print(String(format: "[NiceShot] PoseSpike: analyzing clip at %.2fs of %@",
                         clip.impactTimestamp, video.displayName))

            do {
                let result = try await PoseAnalyzer().analyzeSwing(
                    in: clip.localFileURL,
                    impactTimeInClip: impactInClip,
                    outputDirectory: clipDir
                )
                allURLs.append(contentsOf: result.savedStillURLs)
            } catch {
                print("[NiceShot] PoseSpike: clip analysis failed for \(clip.id): \(error.localizedDescription)")
                continue
            }
        }

        print("[NiceShot] PoseSpike: completed \(clips.count) clip(s) for \(video.displayName)")
        print("[NiceShot] PoseSpike: saved stills to \(sourceDir.path)")

        poseSpikeShareURLs = allURLs
        if !allURLs.isEmpty {
            poseSpikeSharePresented = true
        }
    }
    #endif

    /// Tier 3 control. If the original is already gone we collapse to a
    /// disabled status line — the action wouldn't do anything and a
    /// dimmed red button reads as "still tappable, just broken."
    @ViewBuilder
    private var deleteOriginalControl: some View {
        if video.wasOriginalDeletedFromPhotos {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                Text("Original already deleted from Photos")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } else if video.originalAssetIdentifier == nil {
            // No Photos reference to delete — we never had one or it was
            // lost. Hiding the control entirely is cleaner than showing a
            // perpetually-disabled button.
            EmptyView()
        } else {
            Button {
                runDeleteOriginal()
            } label: {
                if isDeletingOriginal {
                    ProgressView()
                } else {
                    Label("Delete Original from Photos",
                          systemImage: ActionIcon.deleteFromPhotos)
                }
            }
            .buttonStyle(.deleteFromPhotosAction)
            .disabled(isDeletingOriginal)
            .frame(maxWidth: .infinity)
        }
    }

    private func runDeleteOriginal() {
        Task {
            isDeletingOriginal = true
            _ = await app.deleteOriginal(forVideo: video)
            isDeletingOriginal = false
            // Don't auto-dismiss — let the user see the new "Original
            // deleted from Photos" status, and choose when to leave.
        }
    }
}

// MARK: - V4.3 Pose Spike share sheet (DEBUG)

#if DEBUG
/// Thin UIViewControllerRepresentable wrapping UIActivityViewController so
/// the spike's JPEG URLs can be AirDropped / saved to Photos / saved to
/// Files. Used only by the DEBUG "Run Pose Spike" button.
private struct PoseSpikeShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
