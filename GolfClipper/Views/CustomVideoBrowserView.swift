// CustomVideoBrowserView.swift
//
// V2 visual redesign — Instagram-style immersive video grid.
//
// Layout / behaviour:
//   • Pure-black background everywhere (top bar, grid, bottom bar).
//   • Top bar:    ✕ close (left) · "Select Videos" (centre) · Done (N) (right)
//   • Grid:       3 columns, 1pt gaps, each cell 3:4 portrait
//   • Bottom bar: "N videos selected" centred (or dim "No videos selected")
//   • Haptics:    light on toggle, medium on Done
//   • Permission states: notDetermined → ask; authorized → grid;
//                        limited → grid + amber notice;
//                        denied/restricted → PhotosPermissionView
//
// Selection logic, the 20-video cap, and the import handoff are
// unchanged — this redesign is visual only.

import SwiftUI
import Photos
import UIKit

struct CustomVideoBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = PhotosLibraryManager()

    /// Selection state in tap-order. Stored as local identifiers so we
    /// can compare against PHAssets fetched later without holding refs.
    @State private var selectedIDs: [String] = []

    /// Called on Done with the chosen asset identifiers (preserved order).
    var onPick: ([String]) -> Void

    /// Phase 2 — error message surfaced when a context-menu Delete (or
    /// Favorite) fails (permission denied, system rejection, etc.).
    /// User-cancelled deletes are silent.
    @State private var deleteErrorMessage: String?

    /// Phase 2.1 — sliding-window prefetch state. Tracks the highest
    /// asset index we've asked PHCachingImageManager to pre-cache. We
    /// extend the window forward whenever a cell within
    /// `prefetchTriggerDistance` of this index appears.
    @State private var farthestPrefetchedIndex: Int = -1

    /// Service used for context-menu deletion. Reused from the
    /// post-export cleanup feature.
    private let photosDeleter = PhotosDeleteService()

    private static let maxSelection = 20
    private static let columnCount = 3
    private static let gridSpacing: CGFloat = 1
    /// Vertical aspect for cells — 3 wide, 4 tall.
    private static let cellAspect: CGFloat = 3.0 / 4.0
    /// How many cells ahead of the leading visible edge we keep
    /// pre-cached. ~30 cells = 10 rows.
    private static let prefetchAheadCount = 30
    /// Extend the prefetch window when the leading visible cell gets
    /// within this many cells of the current frontier.
    private static let prefetchTriggerDistance = 10

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        // Flat sheet: iOS rounds the top corners of every .sheet by default,
        // which makes the top black bar look like it has rounded corners.
        // Setting the corner radius to 0 flattens the sheet so the bar
        // reads edge-to-edge, Instagram-style.
        .presentationCornerRadius(0)
        .alert("Couldn't delete video",
               isPresented: Binding(get: { deleteErrorMessage != nil },
                                    set: { if !$0 { deleteErrorMessage = nil } })) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.authStatus {
        case .authorized:
            authorizedView(showLimitedNotice: false)
        case .limited:
            authorizedView(showLimitedNotice: true)
        case .notDetermined:
            requestingView
                .task {
                    let status = await manager.requestAuthorization()
                    if status == .authorized || status == .limited {
                        manager.fetchVideos()
                        warmCache()
                    }
                }
        case .denied, .restricted:
            PhotosPermissionView(status: manager.authStatus,
                                 onCancel: { dismiss() })
        @unknown default:
            PhotosPermissionView(status: manager.authStatus,
                                 onCancel: { dismiss() })
        }
    }

    // MARK: - Authorized states

    private func authorizedView(showLimitedNotice: Bool) -> some View {
        VStack(spacing: 0) {
            topBar
            if showLimitedNotice { limitedNotice }
            grid
            bottomBar
        }
        .onAppear {
            if manager.assets.isEmpty {
                manager.fetchVideos()
                warmCache()
            }
        }
        .onDisappear {
            manager.stopAllCaching()
        }
    }

    private var requestingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Requesting Photos access…")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")

                Spacer()

                Button {
                    commit()
                } label: {
                    Text(selectedIDs.isEmpty ? "Done" : "Done (\(selectedIDs.count))")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(selectedIDs.isEmpty
                                         ? Color.white.opacity(0.35)
                                         : .white)
                }
                .disabled(selectedIDs.isEmpty)
            }

            Text("Select Videos")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black)
    }

    private func commit() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()
        onPick(selectedIDs)
        dismiss()
    }

    // MARK: - Limited notice

    private var limitedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.yellow)
            Text("Nice Shot can only see videos you've allowed.")
                .font(.caption)
                .foregroundStyle(.white)
            Spacer()
            Button("Manage") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption.bold())
            .foregroundStyle(.yellow)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { geo in
            // Numeric cell size — used for both the column width and the
            // PHCachingImageManager target. Computed once per layout.
            let totalGaps = Self.gridSpacing * CGFloat(Self.columnCount - 1)
            let cellWidth = (geo.size.width - totalGaps) / CGFloat(Self.columnCount)
            let cellHeight = cellWidth / Self.cellAspect  // = cellWidth × 4/3

            // Fixed-width columns mean SwiftUI doesn't need to recompute
            // column geometry on scroll. Combined with explicit per-cell
            // .frame, this gives the layout engine zero work during scroll.
            let columns = Array(
                repeating: GridItem(.fixed(cellWidth), spacing: Self.gridSpacing),
                count: Self.columnCount
            )

            // We keep `manager.assets` as `[PHAsset]` rather than a raw
            // PHFetchResult: PHAssets are lightweight metadata refs, and
            // SwiftUI's ForEach needs an Identifiable collection. The
            // cost of enumerating the result once at fetch time is
            // negligible compared to the win in code clarity and
            // animatable removal for context-menu deletions.
            ScrollView {
                if manager.assets.isEmpty {
                    emptyMessage
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(Array(manager.assets.enumerated()),
                                id: \.element.localIdentifier) { idx, asset in
                            VideoThumbnailCell(
                                asset: asset,
                                selectionIndex: selectionIndex(for: asset),
                                manager: manager,
                                onTap: { toggleSelection(for: asset) },
                                onDelete: { deleteAsset(asset) },
                                onToggleFavorite: { toggleFavorite(for: asset) }
                            )
                            .frame(width: cellWidth, height: cellHeight)
                            .onAppear {
                                ensurePrefetched(forIndex: idx)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(Color.black)
            .onAppear {
                // Pin the manager's thumbnail target size in pixels.
                // 3:4 portrait — match the rendered cell shape so we
                // don't waste memory loading wider-than-needed images.
                let scale = UIScreen.main.scale
                manager.thumbnailTargetSize = CGSize(
                    width:  cellWidth  * scale,
                    height: cellHeight * scale
                )
            }
        }
    }

    private var emptyMessage: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.4))
            Text("No videos in your library yet.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            if selectedIDs.isEmpty {
                Text("No videos selected")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.3))
            } else {
                Text("\(selectedIDs.count) video\(selectedIDs.count == 1 ? "" : "s") selected")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .background(Color.black)
    }

    // MARK: - Selection logic

    private func selectionIndex(for asset: PHAsset) -> Int? {
        guard let pos = selectedIDs.firstIndex(of: asset.localIdentifier) else {
            return nil
        }
        return pos + 1
    }

    private func toggleSelection(for asset: PHAsset) {
        let id = asset.localIdentifier
        let gen = UIImpactFeedbackGenerator(style: .light)

        if let pos = selectedIDs.firstIndex(of: id) {
            // Deselect — remaining badges renumber automatically because
            // selectionIndex(for:) reads the index from the array.
            selectedIDs.remove(at: pos)
            gen.impactOccurred()
            return
        }
        guard selectedIDs.count < Self.maxSelection else {
            // Soft-cap — silently ignore. No haptic so the user gets
            // a passive "nothing happened" cue.
            return
        }
        selectedIDs.append(id)
        gen.impactOccurred()
    }

    // MARK: - Phase 2 — delete from Photos via long-press

    /// Run Apple's system deletion dialog for one asset. On success
    /// (or notFound — already gone), drop the row from the grid with a
    /// fade-out animation and remove it from the current selection.
    /// User cancellation is silent; permission-denied / hard failures
    /// surface as an alert.
    private func deleteAsset(_ asset: PHAsset) {
        let assetID = asset.localIdentifier
        Task {
            do {
                let result = try await photosDeleter.deleteOriginal(assetIdentifier: assetID)
                switch result.outcome {
                case .deleted, .notFound:
                    withAnimation(.easeOut(duration: 0.25)) {
                        manager.removeAsset(withIdentifier: assetID)
                        // Selection badges renumber automatically because
                        // selectionIndex(for:) reads positional index from
                        // selectedIDs — removing the entry shifts the rest.
                        selectedIDs.removeAll { $0 == assetID }
                    }
                case .userCancelled:
                    // User tapped Cancel in Apple's system dialog. Keep
                    // the cell exactly where it is.
                    break
                case .failed(let msg):
                    deleteErrorMessage = msg
                }
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Phase 2.1 — toggle favorite via long-press

    /// Fire-and-forget toggle of the Photos favorite flag. The cell
    /// won't visually change until the next time the browser is
    /// presented (PHAsset properties are read-only snapshots). Errors
    /// surface in the same alert as Delete.
    private func toggleFavorite(for asset: PHAsset) {
        Task {
            do {
                try await manager.toggleFavorite(for: asset)
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Cache warming + scroll-aware prefetch

    /// Pre-cache the first window of thumbnails on appear. Sliding-window
    /// extension afterwards is handled by `ensurePrefetched(forIndex:)`
    /// from each cell's onAppear.
    private func warmCache() {
        let windowCount = min(90, manager.assets.count)  // ~30 rows
        guard windowCount > 0 else { return }
        let window = Array(manager.assets.prefix(windowCount))
        manager.startCaching(for: window)
        farthestPrefetchedIndex = windowCount - 1
    }

    /// Called from each cell's onAppear. When the visible cell index
    /// gets within `prefetchTriggerDistance` of the cached frontier,
    /// extend the cache window by `prefetchAheadCount` more cells. This
    /// is how PHCachingImageManager stays ahead of the user's scroll
    /// without us having to track scroll position directly.
    private func ensurePrefetched(forIndex index: Int) {
        guard !manager.assets.isEmpty else { return }

        // If the asset count shrank (user deleted), clamp the frontier.
        if farthestPrefetchedIndex >= manager.assets.count {
            farthestPrefetchedIndex = manager.assets.count - 1
        }

        // Trigger only when the cell is near the leading edge.
        guard index >= farthestPrefetchedIndex - Self.prefetchTriggerDistance else {
            return
        }

        let lo = farthestPrefetchedIndex + 1
        let hi = min(manager.assets.count, index + Self.prefetchAheadCount + 1)
        guard hi > lo else { return }

        let window = Array(manager.assets[lo..<hi])
        manager.startCaching(for: window)
        farthestPrefetchedIndex = hi - 1
    }
}
