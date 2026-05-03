// ReviewSelectedVideosView.swift
//
// Sheet presented after the user selects videos in the Photos picker
// but BEFORE the app starts processing them. Lets the user:
//   • remove a video from the import queue (Photos copy is left alone)
//   • delete a video's original from Photos (via PhotosDeleteService)
//   • commit the surviving list with "Start Clipping"
//
// Important UX distinction (per spec):
//   "Remove from Queue"   → don't process, keep in Photos
//   "Delete from Photos"  → delete from Photos via Apple's system dialog;
//                           on success, also drop from the queue.
// V4 — both buttons adopt the shared ActionButtonStyles tier system so
// the visual gap between Tier 1 (gray text) and Tier 3 (red outlined)
// matches the gap between the two stakes.

import SwiftUI

struct ReviewSelectedVideosView: View {
    @Environment(\.dismiss) private var dismiss

    /// Live queue. Bound from HomeView so removals/deletions reflect
    /// upward and the parent can read the survivors on commit.
    @Binding var items: [PendingVideoImport]

    /// What the user originally picked, frozen at sheet-open time. Used
    /// for the "X videos selected" line so it stays stable while the
    /// "ready to clip" line decreases as items are removed.
    let initialCount: Int

    /// Called when the user taps Start Clipping. Parent stashes the
    /// surviving picker items and triggers the analysis sheet.
    var onStartClipping: () -> Void

    /// Service used for per-video deletion. Reused from the post-export
    /// cleanup feature — Apple's system confirmation is the safeguard.
    private let photosDeleter = PhotosDeleteService()

    @State private var actionMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    queueList
                }
            }
            .navigationTitle("Review Videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        items = []
                        dismiss()
                    }
                }
            }
            .alert("Originals",
                   isPresented: Binding(get: { actionMessage != nil },
                                        set: { if !$0 { actionMessage = nil } })) {
                Button("OK", role: .cancel) { actionMessage = nil }
            } message: { Text(actionMessage ?? "") }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No videos selected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Add videos to start clipping.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Queue list

    private var queueList: some View {
        VStack(spacing: 0) {
            counts
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 8)

            List {
                ForEach(items) { item in
                    VideoReviewCard(
                        item: item,
                        onRemoveFromQueue: { removeFromQueue(item) },
                        onDeleteOriginal:  { deleteOriginal(item) }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .animation(.default, value: items.map(\.id))

            startButton
                .padding()
                .background(.bar)
        }
    }

    private var counts: some View {
        VStack(spacing: 4) {
            Text("\(initialCount) video\(initialCount == 1 ? "" : "s") selected")
                .font(.headline)
            Text("\(items.count) video\(items.count == 1 ? "" : "s") ready to clip")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Remove videos from this batch or delete originals from Photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private var startButton: some View {
        Button {
            onStartClipping()
            dismiss()
        } label: {
            Text("Start Clipping")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(items.isEmpty ? Color.gray : Color.green)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(items.isEmpty)
    }

    // MARK: - Actions

    private func removeFromQueue(_ item: PendingVideoImport) {
        items.removeAll { $0.id == item.id }
    }

    private func deleteOriginal(_ item: PendingVideoImport) {
        let assetID = item.assetIdentifier
        Task {
            do {
                let result = try await photosDeleter.deleteOriginal(assetIdentifier: assetID)
                switch result.outcome {
                case .deleted:
                    items.removeAll { $0.id == item.id }
                    actionMessage = "Original deleted from Photos."
                case .notFound:
                    items.removeAll { $0.id == item.id }
                    actionMessage = "That video was already removed from Photos."
                case .userCancelled:
                    // Apple's system dialog was cancelled. Silent —
                    // item stays in queue, no error shown.
                    break
                case .failed(let msg):
                    if let idx = items.firstIndex(where: { $0.id == item.id }) {
                        items[idx].deletionErrorMessage = msg
                    }
                    actionMessage = "Couldn't delete original: \(msg)"
                }
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Video review card

private struct VideoReviewCard: View {
    let item: PendingVideoImport
    let onRemoveFromQueue: () -> Void
    let onDeleteOriginal: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayFilename)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if let duration = item.duration {
                        Text(TimeFormatter.mmss(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let err = item.deletionErrorMessage {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }

            // V4 — Tier 1 gray text link vs Tier 3 red outlined button.
            // The visual asymmetry IS the safety mechanism — never let
            // these two be the same size or color.
            HStack(spacing: 12) {
                Button("Remove from Queue", action: onRemoveFromQueue)
                    .buttonStyle(.removeAction)

                Spacer()

                Button(action: onDeleteOriginal) {
                    Label("Delete from Photos",
                          systemImage: ActionIcon.deleteFromPhotos)
                }
                .buttonStyle(.deleteFromPhotosAction)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = item.thumbnail {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemBackground))
                .frame(width: 80, height: 60)
                .overlay(
                    Image(systemName: "video")
                        .foregroundStyle(.secondary)
                )
        }
    }

    /// Falls back to a simple "Video" label when we couldn't read the
    /// PHAssetResource filename (no read access, or missing identifier).
    private var displayFilename: String {
        if let n = item.originalFilename, !n.isEmpty { return n }
        return "Video"
    }
}

#Preview {
    @Previewable @State var items: [PendingVideoImport] = []
    return ReviewSelectedVideosView(items: $items, initialCount: 0) {}
}
