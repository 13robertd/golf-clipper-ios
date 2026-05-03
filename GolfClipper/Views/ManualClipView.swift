// ManualClipView.swift
// Plays the original imported video so the user can scrub to the impact
// frame and create a clip there. This is the fallback for shots that
// audio detection misses (or when the video has no audio at all).
//
// V1.5: this view is always presented inside `ManualClipFlow`, which owns
// the NavigationStack and Done button — so this view just declares its
// title and content.

import SwiftUI
import AVKit
import AVFoundation

struct ManualClipView: View {
    @EnvironmentObject var app: AppState
    let video: ImportedVideo

    @State private var player: AVPlayer
    @State private var currentTime: Double = 0
    @State private var isCreating = false
    @State private var statusMessage: String?
    @State private var observerToken: Any?

    init(video: ImportedVideo) {
        self.video = video
        _player = State(initialValue: AVPlayer(url: video.localFileURL))
    }

    var body: some View {
        VStack(spacing: 16) {
            VideoPlayer(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                Text("Tap → to scrub to the impact moment, then tap Create Clip Here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack {
                    Text(TimeFormatter.mmssTenths(currentTime))
                    Spacer()
                    Text(TimeFormatter.mmss(video.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

                Slider(value: Binding(
                    get: { currentTime },
                    set: { newValue in
                        currentTime = newValue
                        player.seek(to: CMTime(seconds: newValue, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
                    }),
                    in: 0...max(video.duration, 0.1))
                .padding(.horizontal)

                HStack(spacing: 10) {
                    nudgeButton(label: "−1s", delta: -1)
                    nudgeButton(label: "−0.1s", delta: -0.1)
                    nudgeButton(label: "+0.1s", delta: 0.1)
                    nudgeButton(label: "+1s", delta: 1)
                }
                .padding(.horizontal)
            }

            Button {
                Task {
                    isCreating = true
                    statusMessage = nil
                    await app.createManualClip(forVideo: video, atTime: currentTime)
                    isCreating = false
                    if app.errorMessage == nil {
                        statusMessage = "Clip created at \(TimeFormatter.mmssTenths(currentTime))."
                    }
                }
            } label: {
                Group {
                    if isCreating {
                        ProgressView()
                    } else {
                        Label("Create Clip Here", systemImage: "scissors")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            .disabled(isCreating)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.bottom)
        .navigationTitle("Manual Clip")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { startObservingTime() }
        .onDisappear { stopObservingTime() }
    }

    private func nudgeButton(label: String, delta: Double) -> some View {
        Button {
            let next = max(0, min(video.duration, currentTime + delta))
            currentTime = next
            player.seek(to: CMTime(seconds: next, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        } label: {
            Text(label)
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func startObservingTime() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        observerToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = CMTimeGetSeconds(time)
        }
    }

    private func stopObservingTime() {
        if let token = observerToken {
            player.removeTimeObserver(token)
            observerToken = nil
        }
        player.pause()
    }
}
