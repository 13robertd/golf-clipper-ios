// ClipPlayerView.swift
// Plays a single clip. V1.7 simplifies the action area: a single
// Save-to-Photos button (or a "Saved to Photos" status pill once it's
// already in Photos), and a subtle "Remove Clip" text link at the
// bottom. We renamed Delete → Remove Clip so users don't confuse
// removing a clip from the app with deleting the original from Photos.
// V4 — both buttons now use the shared ActionButtonStyles tier system.

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

    /// Trimmed in V1.7: no more "Saved to Photos" line here — that
    /// information is now part of the action area below so there's
    /// exactly one place to look.
    private var details: some View {
        VStack(spacing: 4) {
            Text("Impact at \(TimeFormatter.mmssTenths(clip.impactTimestamp))")
                .font(.headline)
            Text("Length \(TimeFormatter.seconds(clip.duration)) • \(TimeFormatter.mmssTenths(clip.startTime)) → \(TimeFormatter.mmssTenths(clip.endTime))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    /// V1.7 action area:
    ///   • Saved to Photos? → green status pill (no button)
    ///   • Not saved?       → green Save to Photos button
    /// + "Remove Clip" subtle text link below.
    private var actions: some View {
        VStack(spacing: 14) {
            if clip.isSavedToPhotos {
                savedPill
            } else {
                saveButton
            }
            removeClipLink
        }
        .padding(.horizontal)
    }

    private var savedPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text("Saved to Photos")
        }
        .font(.headline)
        .foregroundStyle(.green)
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var saveButton: some View {
        Button {
            Task {
                isSaving = true
                await app.saveClipToPhotos(clip)
                isSaving = false
            }
        } label: {
            if isSaving {
                ProgressView()
                    .tint(.white)
            } else {
                Label("Save to Photos", systemImage: ActionIcon.save)
            }
        }
        .buttonStyle(.saveAction)
        .disabled(isSaving)
    }

    private var removeClipLink: some View {
        Button("Remove Clip") {
            app.deleteClip(clip)
            dismiss()
        }
        .buttonStyle(.removeAction)
        .accessibilityLabel("Remove clip from this app")
    }
}
