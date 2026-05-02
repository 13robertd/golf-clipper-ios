// ClipPlayerView.swift
// Plays a single clip and lets the user save it to Photos or delete it.

import SwiftUI
import AVKit

struct ClipPlayerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let clip: SwingClip

    @State private var player: AVPlayer?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 16) {
            videoPlayer
                .frame(maxHeight: .infinity)

            details
            actions
        }
        .padding(.bottom)
        .navigationTitle("Clip")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            player = AVPlayer(url: clip.localFileURL)
            player?.play()
        }
        .onDisappear { player?.pause() }
    }

    private var videoPlayer: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.black
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var details: some View {
        VStack(spacing: 4) {
            Text("Impact at \(TimeFormatter.mmssTenths(clip.impactTimestamp))")
                .font(.headline)
            Text("Length \(TimeFormatter.seconds(clip.duration)) • \(TimeFormatter.mmssTenths(clip.startTime)) → \(TimeFormatter.mmssTenths(clip.endTime))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if clip.isSavedToPhotos {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                app.deleteClip(clip)
                dismiss()
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button {
                Task {
                    isSaving = true
                    await app.saveClipToPhotos(clip)
                    isSaving = false
                }
            } label: {
                Group {
                    if isSaving {
                        ProgressView()
                    } else {
                        Label("Save to Photos", systemImage: "square.and.arrow.up")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isSaving)
        }
        .padding(.horizontal)
    }
}
