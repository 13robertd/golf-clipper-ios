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

    /// Whether the local imported file actually exists on disk. If the
    /// user manually deleted it (or the sandbox path drifted), we still
    /// show the metadata but replace the player with an explanation.
    private var hasPlayableLocalCopy: Bool {
        FileManager.default.fileExists(atPath: video.localFileURL.path)
    }

    private var clipCount: Int {
        app.clips.filter { $0.sourceVideoId == video.id }.count
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
        }
    }

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
