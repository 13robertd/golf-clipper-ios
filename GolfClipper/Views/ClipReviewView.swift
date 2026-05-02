// ClipReviewView.swift
// Lists every clip we've generated. Each row shows a thumbnail, the
// impact time inside the source video, the clip duration, and quick
// actions (play, save to Photos, delete).

import SwiftUI
import AVKit

struct ClipReviewView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var savingAll = false

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
                ToolbarItem(placement: .topBarTrailing) {
                    if !app.clips.isEmpty {
                        Button {
                            Task {
                                savingAll = true
                                await app.saveAllClipsToPhotos()
                                savingAll = false
                            }
                        } label: {
                            if savingAll {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.up.on.square")
                            }
                        }
                        .accessibilityLabel("Save All to Photos")
                    }
                }
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

    private var list: some View {
        List {
            ForEach(app.clips) { clip in
                NavigationLink {
                    ClipPlayerView(clip: clip)
                } label: {
                    ClipRow(clip: clip)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        app.deleteClip(clip)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Task { await app.saveClipToPhotos(clip) }
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.up")
                    }
                    .tint(.green)
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    savingAll = true
                    await app.saveAllClipsToPhotos()
                    savingAll = false
                }
            } label: {
                if savingAll {
                    ProgressView().padding()
                } else {
                    Label("Save All Clips to Photos", systemImage: "square.and.arrow.up.on.square.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
            .background(.bar)
        }
    }
}

// MARK: - Row

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
