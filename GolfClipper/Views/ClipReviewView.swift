// ClipReviewView.swift
// Lists every clip we've generated, grouped by source video.
//
// V1.7 — cleanup banner: instead of the V1.6 modal alert that fired
// after Save All, we surface a persistent banner at the top of the
// list whenever a source video has at least one clip safely in Photos.
// One banner per source video. Two buttons:
//   • "Keep Original" → dismiss for the rest of this app session
//   • "Delete Original from Photos" → calls PhotosDeleteService; Apple's
//     system dialog is the final confirmation.
// On successful delete the banner is replaced by a quiet 3-second
// "✓ Original deleted · X freed" toast that fades on its own.
// V4 — buttons adopt the shared ActionButtonStyles tier system; the
// toolbar Save-all icon was removed so the bottom green bar is the
// single, unambiguous primary action.
// V5 — accepts an optional `scrollToVideoId`. When set (deep-link from
// SourceVideoPreviewView's "View Clips from This Video" button), the
// list scrolls that video's section into view on first appear so the
// user lands directly on their clips instead of hunting for them.
// Group headers now show the video's displayName instead of the raw
// internal filename.

import SwiftUI
import AVKit

/// Per-video transient confirmation row payload. File-private so the
/// banner row (`DeletedConfirmationRow` below) can reference it.
private struct RecentlyDeletedItem: Equatable {
    let filename: String
    let sizeBytes: Int64?
}

struct ClipReviewView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// V5 — when non-nil, the corresponding source-video section is
    /// scrolled into view on appear. Default nil preserves the old
    /// "open from Home / Review Clips" behavior.
    var scrollToVideoId: UUID? = nil

    @State private var savingAll = false

    /// Per-video transient confirmation rows shown for ~3 seconds after
    /// a successful delete. Keyed by video id so we know what just happened.
    /// In-memory, view-local — does not survive sheet dismissal.
    @State private var recentlyDeleted: [UUID: RecentlyDeletedItem] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if app.clips.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                // V4 — toolbar Save-all icon removed. The big green bottom
                // bar is the single primary entry point; two competing
                // buttons for the same action muddied the visual hierarchy.
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { app.errorMessage != nil },
                                        set: { if !$0 { app.errorMessage = nil } })) {
                Button("OK", role: .cancel) { app.errorMessage = nil }
            } message: { Text(app.errorMessage ?? "") }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scissors")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No clips yet")
                .font(.headline)
            Text("Import a video and we'll generate clips automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - Save flow

    private func runSaveAll() {
        Task {
            savingAll = true
            await app.saveAllClipsToPhotos()
            savingAll = false
            // V1.7: no alert here. The banner section at the top of the
            // list now reflects the new save state automatically.
        }
    }

    // MARK: - Banner data

    /// Banners to render right now — eligible videos minus session-dismissed,
    /// minus those already showing a "just deleted" toast.
    private var bannerVideos: [ImportedVideo] {
        app.videosWithCleanupBanner.filter { video in
            !app.dismissedCleanupBannerVideoIDs.contains(video.id)
                && recentlyDeleted[video.id] == nil
        }
    }

    // MARK: - Banner actions

    private func handleKeep(_ video: ImportedVideo) {
        app.dismissCleanupBanner(forVideo: video)
    }

    private func handleDelete(_ video: ImportedVideo) {
        // Capture file size BEFORE the call — once the record flips to
        // wasOriginalDeletedFromPhotos = true the row leaves the eligible
        // list, so we'd lose the value for the toast otherwise.
        // V5 — toast uses displayName too; don't leak the raw filename.
        let snapshotSize = video.fileSizeBytes
        let snapshotName = video.displayName
        let videoID = video.id

        Task {
            let result = await app.deleteOriginal(forVideo: video)
            switch result {
            case .deleted:
                // Show 3-second confirmation toast, then clear it. The
                // video is already gone from the eligible list because
                // wasOriginalDeletedFromPhotos is now true, so the banner
                // disappears together with the toast.
                recentlyDeleted[videoID] = RecentlyDeletedItem(
                    filename: snapshotName,
                    sizeBytes: snapshotSize
                )
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                recentlyDeleted.removeValue(forKey: videoID)
            case .userCancelled:
                // Silent. Banner stays visible.
                break
            case .failed:
                // The errorMessage alert (bound to app.errorMessage from
                // PhotosDeleteService permission failures) covers this.
                break
            case .missingIdentifier:
                app.errorMessage = "Some original videos could not be deleted because their Photos reference was unavailable."
            }
        }
    }

    // MARK: - Grouped list

    private var list: some View {
        // V5 — ScrollViewReader so the list can deep-link to a specific
        // source-video section (set via `scrollToVideoId` on init).
        ScrollViewReader { proxy in
        List {
            // V1.7 cleanup banners + post-delete confirmation toasts.
            // Wrapped in a single section with no header so they sit at
            // the very top of the scroll, above the per-video sections.
            if !bannerVideos.isEmpty || !recentlyDeleted.isEmpty {
                Section {
                    ForEach(bannerVideos) { video in
                        OriginalCleanupBanner(
                            video: video,
                            onKeep: { handleKeep(video) },
                            onDelete: { handleDelete(video) }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(Array(recentlyDeleted.keys), id: \.self) { id in
                        if let item = recentlyDeleted[id] {
                            DeletedConfirmationRow(item: item)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .transition(.opacity)
                        }
                    }
                }
            }

            ForEach(groupedClips, id: \.videoId) { group in
                Section {
                    ForEach(group.clips) { clip in
                        NavigationLink {
                            ClipPlayerView(clip: clip)
                        } label: {
                            ClipRow(clip: clip)
                        }
                        // V4 — swipe slot uses Tier 1 wording ("Remove",
                        // app-level) and drops `role: .destructive` so the
                        // slot isn't red. Red is reserved for Tier 3
                        // Photos-level delete actions.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                app.deleteClip(clip)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                            .tint(.gray)
                            Button {
                                Task { await app.saveClipToPhotos(clip) }
                            } label: {
                                Label("Save", systemImage: ActionIcon.save)
                            }
                            .tint(.green)
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "video.fill").foregroundStyle(.green)
                        Text(group.title)
                            .lineLimit(1)
                        Spacer()
                        Text("\(group.clips.count) clip\(group.clips.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                }
                .id(group.videoId)
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: bannerVideos.map(\.id))
        .animation(.default, value: Array(recentlyDeleted.keys))
        // V5 — Deferred a beat so the List has rendered its sections
        // before we ask it to scroll. Without the small delay,
        // proxy.scrollTo silently no-ops on first present.
        .onAppear {
            guard let target = scrollToVideoId else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation { proxy.scrollTo(target, anchor: .top) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                runSaveAll()
            } label: {
                if savingAll {
                    ProgressView()
                        .tint(.white)
                } else {
                    Label("Save All to Photos", systemImage: ActionIcon.save)
                }
            }
            .buttonStyle(.saveAction)
            .disabled(savingAll)
            .padding()
            .background(.bar)
        }
        }   // ScrollViewReader
    }

    // MARK: - Grouping

    private struct ClipGroup {
        let videoId: UUID
        let title: String
        let clips: [SwingClip]
    }

    private var groupedClips: [ClipGroup] {
        var groups: [ClipGroup] = []
        for video in app.importedVideos {
            let videoClips = app.clips
                .filter { $0.sourceVideoId == video.id }
                .sorted { $0.impactTimestamp < $1.impactTimestamp }
            if !videoClips.isEmpty {
                // V5 — friendly name (date-based) instead of the raw
                // PHAssetResource filename. See VideoDisplayName.swift.
                groups.append(ClipGroup(videoId: video.id,
                                        title: video.displayName,
                                        clips: videoClips))
            }
        }
        let known = Set(app.importedVideos.map { $0.id })
        let orphans = app.clips
            .filter { !known.contains($0.sourceVideoId) }
            .sorted { $0.impactTimestamp < $1.impactTimestamp }
        if !orphans.isEmpty {
            groups.append(ClipGroup(videoId: UUID(),
                                    title: "Source video missing",
                                    clips: orphans))
        }
        return groups
    }
}

// MARK: - Cleanup banner

private struct OriginalCleanupBanner: View {
    let video: ImportedVideo
    let onKeep: () -> Void
    let onDelete: () -> Void

    /// V4 — body text comes straight from the action-language spec.
    /// The previous version mixed clip count + bytes-saved into the body;
    /// the new copy keeps the message short and the bytes-freed info
    /// surfaces in the post-delete confirmation toast instead.
    private let bodyText = "Your clips were saved to Photos. Want to delete the original video to free up space? It'll stay in Recently Deleted for 30 days."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // V5 — displayName, not the raw originalFilename.
            Text(video.displayName)
                .font(.subheadline.bold())
                .lineLimit(1)

            Text(bodyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // V4 — Tier 1 "Keep Original" gray text link vs Tier 3 red
            // outlined "Delete Original from Photos". The visual gap
            // between them is the entire point: the user must never
            // mistake one for the other.
            HStack(spacing: 12) {
                Spacer()
                Button("Keep Original", action: onKeep)
                    .buttonStyle(.removeAction)

                Button(action: onDelete) {
                    Label("Delete Original from Photos",
                          systemImage: ActionIcon.deleteFromPhotos)
                }
                .buttonStyle(.deleteFromPhotosAction)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Post-delete confirmation toast row

private struct DeletedConfirmationRow: View {
    let item: RecentlyDeletedItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var detailText: String {
        if let size = ByteFormatter.human(item.sizeBytes) {
            return "Original deleted · \(size) freed"
        }
        return "Original deleted"
    }
}

// MARK: - Clip row

private struct ClipRow: View {
    let clip: SwingClip

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if clip.isManual {
                        Text("MANUAL")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    if clip.isSavedToPhotos {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text("Impact \(TimeFormatter.mmssTenths(clip.impactTimestamp))")
                    .font(.headline)
                Text(TimeFormatter.seconds(clip.duration))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = clip.thumbnailURL,
           let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 80, height: 60)
                .overlay(Image(systemName: "video").foregroundStyle(.secondary))
        }
    }
}

#Preview {
    ClipReviewView().environmentObject(AppState())
}
