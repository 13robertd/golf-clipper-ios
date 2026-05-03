// VideoThumbnailCell.swift
//
// One cell of the custom video browser grid. V2 redesign:
//   • 3:4 portrait aspect (taller than wide; matches phone-shot golf
//     videos and gives the grid an immersive feel)
//   • Dark-gray (#1A1A1A) loading placeholder so empty cells fade
//     seamlessly into the black background
//   • Full-cell gradient that goes clear → black at 60% opacity over
//     the bottom 30% — keeps the duration label readable on bright
//     thumbnails without darkening the whole image
//   • Larger 13pt semibold duration label, bottom-right with 6pt padding
//   • Selection badge: 24pt blue circle, 1.5pt white stroke, 13pt bold
//     white number, top-right with 6pt padding
//   • Selected cells get a 15% black overlay so selected vs unselected
//     reads at a glance
//
// Loads via the shared PHCachingImageManager (PhotosLibraryManager) and
// cancels its request on disappear so memory and thread time don't pile
// up while the user scrolls.

import SwiftUI
import Photos

struct VideoThumbnailCell: View {
    let asset: PHAsset
    /// 1-based selection number for the badge, or nil when unselected.
    let selectionIndex: Int?
    let manager: PhotosLibraryManager
    let onTap: () -> Void
    /// Phase 2 — invoked when the user picks "Delete from Photos" from
    /// the long-press context menu. Parent handles confirmation (Apple's
    /// system dialog) and grid removal.
    let onDelete: () -> Void
    /// Phase 2.1 — toggle the Photos favorite flag for this asset.
    let onToggleFavorite: () -> Void

    private var isSelected: Bool { selectionIndex != nil }
    private var isFavorite: Bool { asset.isFavorite }

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var isPressed = false

    /// Placeholder fill: Instagram-dark gray (#1A1A1A).
    private static let placeholderColor = Color(
        red:   26.0 / 255.0,
        green: 26.0 / 255.0,
        blue:  26.0 / 255.0
    )

    var body: some View {
        Rectangle()
            .fill(Self.placeholderColor)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            // Bottom-30% darkening gradient — clear over the top 70%,
            // ramping to black at 60% opacity at the very bottom edge.
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear,                       location: 0.0),
                        .init(color: .clear,                       location: 0.70),
                        .init(color: Color.black.opacity(0.60),    location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            // Duration pill, bottom-right.
            .overlay(alignment: .bottomTrailing) {
                Text(formatDuration(asset.duration))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
                    .shadow(color: Color.black.opacity(0.6), radius: 1, x: 0, y: 1)
                    .allowsHitTesting(false)
            }
            // Selected-state dimming overlay.
            .overlay {
                if selectionIndex != nil {
                    Color.black.opacity(0.15)
                        .allowsHitTesting(false)
                }
            }
            // Selection badge, top-right.
            .overlay(alignment: .topTrailing) {
                if let n = selectionIndex {
                    selectionBadge(number: n)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            // 3:4 portrait squeeze + clip — placed AFTER overlays so the
            // overlays inherit the squared portrait bounds.
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .contentShape(Rectangle())
            .onTapGesture {
                isPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    isPressed = false
                }
                onTap()
            }
            // Phase 2 — long-press context menu. iOS handles the peek
            // animation, blur background, and haptic itself; we just
            // declare the items + a larger preview view.
            //
            // Item order (Instagram-style, short labels):
            //   1. Select / Deselect
            //   2. Favorite / Unfavorite
            //   3. Delete from Photos  (Tier 3, destructive)
            .contextMenu {
                Button {
                    onTap()
                } label: {
                    if isSelected {
                        Label("Deselect", systemImage: "xmark.circle")
                    } else {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                }
                Button {
                    onToggleFavorite()
                } label: {
                    if isFavorite {
                        Label("Unfavorite", systemImage: "heart.fill")
                    } else {
                        Label("Favorite", systemImage: "heart")
                    }
                }
                // V4 — Tier 3 (Photos-level): label always names Photos
                // explicitly; .destructive role lets iOS render it red,
                // which matches the Tier 3 visual language.
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete from Photos", systemImage: ActionIcon.deleteFromPhotos)
                }
            } preview: {
                contextPreview
            }
            // Fade out smoothly when the cell is removed from the grid
            // (e.g. after the user deletes the original from Photos).
            .transition(.opacity)
            .onAppear { startLoading() }
            .onDisappear { cancelLoading() }
    }

    // MARK: - Context-menu preview

    /// Larger version of the thumbnail shown when iOS expands the
    /// long-press peek. Sized 360×480 (3:4 portrait) with rounded
    /// corners so it feels like a polished card.
    private var contextPreview: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Self.placeholderColor
            }
        }
        .frame(width: 360, height: 480)
        .overlay(alignment: .bottomTrailing) {
            Text(formatDuration(asset.duration))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6), in: Capsule())
                .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Selection badge

    private func selectionBadge(number: Int) -> some View {
        ZStack {
            Circle()
                .fill(Color.blue)
            Circle()
                .stroke(Color.white, lineWidth: 1.5)
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
    }

    // MARK: - Image loading

    private func startLoading() {
        cancelLoading()
        requestID = manager.requestThumbnail(for: asset) { img in
            // .opportunistic delivers a low-res then high-res image;
            // we just overwrite — last write wins, identical params
            // mean the second image is always at least as good.
            if let img { self.image = img }
        }
    }

    private func cancelLoading() {
        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
