// HomeView.swift
// First screen the user sees. V1.5 supports multi-video import, so the
// imported-video card became a scrollable list of per-video rows. V2
// replaces SwiftUI's PhotosPicker with the custom CustomVideoBrowserView.
// V4 — secondary actions adopt the shared ActionButtonStyles tier system.
// "Clear All" became "Remove All Clips" (Tier 1) and is gated by a
// confirmation dialog: the action is app-level (no Photos delete), so
// the spec puts it in Tier 1, but wiping every clip + every imported
// video with zero confirmation is too sharp an edge — the dialog is the
// safety net that the Tier 1 visual style intentionally lacks.
// V5 — "Imported Videos" → "Source Videos" with thumbnail rows. Tapping
// a row opens SourceVideoPreviewView in a sheet; from there the user
// can sheet-handoff to ClipReviewView with auto-scroll to the matching
// group via `reviewScrollTarget`.

import SwiftUI
import AVFoundation

struct HomeView: View {
    @EnvironmentObject var app: AppState

    @State private var showCustomBrowser = false    // V2 — custom video grid
    @State private var showVideoReview = false      // V1.8 — pre-process review
    @State private var showAnalysis = false
    @State private var showReview = false           // post-process clip list
    @State private var showManualClip = false
    @State private var showSettings = false
    @State private var showRemoveAllConfirm = false   // V4 — Tier 1 safety dialog

    // V5 — Source-video preview sheet + deep-link handoff to ClipReviewView.
    @State private var sourceVideoPreviewTarget: ImportedVideo?
    @State private var pendingReviewScrollTarget: UUID?
    @State private var reviewScrollTarget: UUID?

    // V2 — Photos asset identifiers picked by the custom browser, held
    // briefly across the browser→review sheet handoff.
    @State private var pickedAssetIDs: [String] = []
    @State private var pendingReviewAfterBrowser = false

    // V1.8 — pre-process review queue
    @State private var pendingItems: [PendingVideoImport] = []
    @State private var initialPendingCount: Int = 0
    /// Survivors of the review screen, snapshotted so we can hand them
    /// to importVideos without holding a stale binding.
    @State private var clippingIDsAfterReview: [String] = []
    /// Set when the user taps Start Clipping. Read in the review sheet's
    /// onDismiss to chain into the analysis sheet.
    @State private var pendingAnalysisAfterReview = false

    /// True after the analysis sheet finishes; we then auto-present review
    /// on its `onDismiss` so SwiftUI doesn't try to stack two sheets.
    @State private var pendingReviewAfterAnalysis = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                header

                if app.importedVideos.isEmpty {
                    emptyState
                } else {
                    videoListCard
                }

                Spacer(minLength: 8)

                primaryActions

                if !app.importedVideos.isEmpty {
                    secondaryActions
                }
            }
            .padding()
            .navigationTitle("Nice Shot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            // V2: custom video browser → review → analysis. Each handoff
            // uses onDismiss because SwiftUI silently fails when a sheet
            // is replaced by another in the same render pass.
            .sheet(isPresented: $showCustomBrowser,
                   onDismiss: {
                       guard pendingReviewAfterBrowser else { return }
                       pendingReviewAfterBrowser = false
                       guard !pickedAssetIDs.isEmpty else { return }
                       let ids = pickedAssetIDs
                       pickedAssetIDs = []
                       Task {
                           let pending = await PendingVideoImport.build(fromAssetIdentifiers: ids)
                           pendingItems = pending
                           initialPendingCount = pending.count
                           showVideoReview = true
                       }
                   }) {
                CustomVideoBrowserView { ids in
                    pickedAssetIDs = ids
                    pendingReviewAfterBrowser = true
                }
            }
            .sheet(isPresented: $showVideoReview,
                   onDismiss: {
                       guard pendingAnalysisAfterReview else { return }
                       pendingAnalysisAfterReview = false
                       guard !clippingIDsAfterReview.isEmpty else { return }
                       let toProcess = clippingIDsAfterReview
                       clippingIDsAfterReview = []
                       showAnalysis = true
                       Task {
                           await app.importVideos(fromAssetIdentifiers: toProcess)
                       }
                   }) {
                ReviewSelectedVideosView(
                    items: $pendingItems,
                    initialCount: initialPendingCount,
                    onStartClipping: {
                        clippingIDsAfterReview = pendingItems.map { $0.assetIdentifier }
                        pendingAnalysisAfterReview = true
                    }
                )
            }
            .sheet(isPresented: $showAnalysis,
                   onDismiss: {
                       // Trigger review presentation only AFTER analysis sheet
                       // is fully dismissed — avoids SwiftUI's sheet-stacking
                       // race where the second sheet silently fails to present.
                       if pendingReviewAfterAnalysis {
                           pendingReviewAfterAnalysis = false
                           if !app.clips.isEmpty {
                               showReview = true
                           }
                       }
                   }) {
                VideoAnalysisView(onDone: {
                    pendingReviewAfterAnalysis = !app.clips.isEmpty
                    showAnalysis = false
                })
            }
            .sheet(isPresented: $showReview, onDismiss: {
                // V5 — clear the deep-link target so the next manual open
                // doesn't auto-scroll to a stale section.
                reviewScrollTarget = nil
            }) {
                ClipReviewView(scrollToVideoId: reviewScrollTarget)
            }
            // V5 — Source-video preview. Uses item-binding so each tap
            // re-presents with the right video. The .onDismiss handles the
            // sheet-handoff into ClipReviewView when the user tapped
            // "View Clips from This Video" inside the preview.
            .sheet(item: $sourceVideoPreviewTarget,
                   onDismiss: {
                       guard let target = pendingReviewScrollTarget else { return }
                       pendingReviewScrollTarget = nil
                       reviewScrollTarget = target
                       showReview = true
                   }) { video in
                SourceVideoPreviewView(video: video) { videoId in
                    pendingReviewScrollTarget = videoId
                }
                .environmentObject(app)
            }
            .sheet(isPresented: $showManualClip) {
                ManualClipFlow()
            }
            .sheet(isPresented: $showSettings) {
                SettingsDebugView()
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { app.errorMessage != nil },
                                        set: { if !$0 { app.errorMessage = nil } })) {
                Button("OK", role: .cancel) { app.errorMessage = nil }
            } message: {
                Text(app.errorMessage ?? "")
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "scissors")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.green)
            Text("Nice Shot")
                .font(.largeTitle.bold())
            Text("Automatically clip every golf shot from your videos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.horizontal)
        }
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No videos imported yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Import a golf video and Nice Shot will split it into individual shot clips.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// V5 — "Source Videos" card. Each row shows a thumbnail, friendly
    /// title (date-based, never the raw filename), duration, clip count,
    /// and Photos status. Tapping opens SourceVideoPreviewView. Swipe-left
    /// removes the video from the app (Tier 1 — does not touch Photos).
    private var videoListCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Source Videos")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(app.importedVideos.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // List inside a capped frame so a long batch can scroll
            // without pushing the action buttons off-screen.
            List {
                ForEach(app.importedVideos) { video in
                    Button {
                        sourceVideoPreviewTarget = video
                    } label: {
                        SourceVideoRow(
                            video: video,
                            clipCount: app.clips.filter { $0.sourceVideoId == video.id }.count
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    // V4 — Tier 1 swipe slot. "Remove" + non-destructive
                    // role keeps the slot off red; red is for Tier 3
                    // Photos-level deletes only.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            app.deleteVideo(video)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                        .tint(.gray)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: rowsHeight)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// V5 — Tighter cap (4 rows) since each row is now ~88pt tall with a
    /// thumbnail. Past 4, the list scrolls inside the card; the primary
    /// "Import More Videos" button stays visible regardless.
    private var rowsHeight: CGFloat {
        let n = min(app.importedVideos.count, 4)
        return CGFloat(n) * 88 + 12
    }

    private var primaryActions: some View {
        VStack(spacing: 12) {
            // V2: custom video browser instead of PhotosPicker.
            Button {
                showCustomBrowser = true
            } label: {
                Label(app.importedVideos.isEmpty ? "Import Videos" : "Import More Videos",
                      systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: 10) {
            Button {
                showReview = true
            } label: {
                Label("Review Clips (\(app.clips.count))",
                      systemImage: "rectangle.stack.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button {
                showManualClip = true
            } label: {
                Label("Manual Clip", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            // V4 — Tier 1 styling (gray text, no icon, no background) so
            // the visual weight matches the app-level scope. The
            // .confirmationDialog is the safety net that replaces the
            // missing red-button warning.
            Button("Remove All Clips") {
                showRemoveAllConfirm = true
            }
            .buttonStyle(.removeAction)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .confirmationDialog(
                "Remove all clips and imported videos from this app?",
                isPresented: $showRemoveAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove All", role: .destructive) {
                    app.deleteAllClipsAndVideos()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This won't affect your Photos library — originals stay where they are.")
            }
        }
    }
}

// MARK: - Source-video row (V5)

private struct SourceVideoRow: View {
    let video: ImportedVideo
    let clipCount: Int

    /// Generated lazily via AVAssetImageGenerator on first appear. Cost
    /// is fine for ~4–10 visible rows; persisting to disk would require
    /// model + storage changes that aren't in scope.
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView

            VStack(alignment: .leading, spacing: 4) {
                Text(video.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(TimeFormatter.mmss(video.duration))
                    Text("·")
                    Text("\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let extra = secondaryStatus {
                    Text(extra.text)
                        .font(.caption2)
                        .foregroundStyle(extra.color)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .task(id: video.id) {
            await loadThumbnailIfNeeded()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemBackground))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "video.fill")
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 96, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// One extra status line below the row metadata. Deletion state takes
    /// priority once it lands, since it's the most recent user-relevant
    /// fact about the video.
    private var secondaryStatus: (text: String, color: Color)? {
        if video.wasOriginalDeletedFromPhotos {
            return ("Original deleted from Photos", .secondary)
        }
        if video.processingStatus != .completed {
            return (video.processingStatus.displayName, processingColor)
        }
        return nil
    }

    private var processingColor: Color {
        switch video.processingStatus {
        case .completed:
            return .secondary
        case .failed:
            return .red
        case .noAudio, .noShotsFound:
            return .orange
        case .pending, .importing, .analyzing, .detectingShots,
             .validatingMotion, .creatingClips:
            return .blue
        }
    }

    /// Single early frame, scaled to the row's display size. We pick 0.5s
    /// in (not 0) to skip black opening frames common on iPhone captures.
    private func loadThumbnailIfNeeded() async {
        guard thumbnail == nil else { return }
        let url = video.localFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 180)
        let target = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            let cgImage = try await generator.image(at: target).image
            thumbnail = UIImage(cgImage: cgImage)
        } catch {
            // silent — placeholder icon stays
        }
    }
}

#Preview {
    HomeView().environmentObject(AppState())
}
