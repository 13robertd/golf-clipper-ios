// VideoAnalysisView.swift
// Modal sheet shown while a batch of videos is being processed.
//
// V1.5: drives off `app.batchState`, which has three meaningful states:
//   - .running(BatchProgress) — show "Video N of M", filename, current
//     step, and counters
//   - .completed(BatchSummary) — show totals + per-video result list
//   - .failed(message) — show an error icon + message
// (.idle is shown briefly during the gap between the sheet appearing
//  and the batch actually starting; we render a quiet "Preparing…" state.)

import SwiftUI

struct VideoAnalysisView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps the final "Continue" button OR when the
    /// auto-progress timer fires after .completed.
    var onDone: () -> Void

    /// Latch so the manual Continue button and the auto-progress timer
    /// don't both call onDone (would push the review sheet twice).
    @State private var hasFinished = false

    var body: some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
            if !app.batchState.isWorking {
                continueButton
            }
        }
        .interactiveDismissDisabled(app.batchState.isWorking)
        // Auto-navigate to the clip review screen once the batch
        // completes. Brief 1.5s hold so the user sees the summary
        // first; falls through to onDone() = same path as the manual
        // Continue button.
        .onChange(of: app.batchState) { _, newState in
            if case .completed = newState, !hasFinished {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if case .completed = app.batchState, !hasFinished {
                        hasFinished = true
                        dismiss()
                        onDone()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.batchState {
        case .idle:
            idleView
        case .running(let progress):
            runningView(progress)
        case .completed(let summary):
            summaryView(summary)
        case .failed(let msg):
            failedView(msg)
        }
    }

    private var continueButton: some View {
        Button {
            hasFinished = true
            dismiss()
            onDone()
        } label: {
            Text("Continue")
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    // MARK: - Idle / Preparing

    private var idleView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Running

    private func runningView(_ p: BatchProgress) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .padding(.top, 28)

            Text("Video \(p.currentIndex) of \(p.total)")
                .font(.title3.bold())

            if let name = p.currentFilename {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal)
            }

            Text(currentStatusText(p))
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: progressFraction(p))
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)

            // Live per-phase counter. Clip-export and motion-validation
            // both run sequentially over many items, so a prominent
            // counter reassures the user that progress is happening.
            if p.currentStatus == .creatingClips, p.currentClipTotal > 0 {
                Text("\(p.currentClipIndex) of \(p.currentClipTotal) clips created")
                    .font(.title3.bold())
                    .foregroundStyle(.green)
                    .padding(.top, 4)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: p.currentClipIndex)
            } else if p.currentStatus == .validatingMotion, p.currentMotionTotal > 0 {
                Text("\(p.currentMotionIndex) of \(p.currentMotionTotal) candidates validated")
                    .font(.title3.bold())
                    .foregroundStyle(.blue)
                    .padding(.top, 4)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: p.currentMotionIndex)
            }

            HStack(spacing: 12) {
                stat("Clips", "\(p.clipsCreated)")
                if p.failedCount > 0 {
                    stat("Failed", "\(p.failedCount)", color: .red)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    /// Status string shown under the filename. Promotes the generic
    /// phase labels into per-item counters where we have them
    /// (per-clip during export, per-candidate during motion validation),
    /// since long videos with many impacts make the user wonder
    /// whether anything is happening.
    private func currentStatusText(_ p: BatchProgress) -> String {
        switch p.currentStatus {
        case .creatingClips where p.currentClipTotal > 0:
            return "Creating clip \(p.currentClipIndex) of \(p.currentClipTotal)…"
        case .validatingMotion where p.currentMotionTotal > 0:
            return "Validating swing \(p.currentMotionIndex) of \(p.currentMotionTotal)…"
        default:
            return p.currentStatus.displayName
        }
    }

    /// Combine progress across the batch (videos done) with progress
    /// within the current video. Within one video:
    ///   • 0–30 %   audio (importing → analyzing → detecting)
    ///   • 30–70 %  motion validation (advances per validated candidate)
    ///   • 70–100 % clip creation (advances per finished clip)
    /// When motion validation is disabled the bar simply jumps from 30
    /// straight to 70 once clip creation begins.
    private func progressFraction(_ p: BatchProgress) -> Double {
        guard p.total > 0 else { return 0 }

        let stepWeight: Double
        switch p.currentStatus {
        case .pending, .importing:
            stepWeight = 0.0
        case .analyzing:
            stepWeight = 0.10
        case .detectingShots:
            stepWeight = 0.30                  // audio phase done
        case .validatingMotion:
            // Linear 0.30 → 0.70 across the validation pass.
            if p.currentMotionTotal > 0 {
                let frac = Double(p.currentMotionIndex) / Double(p.currentMotionTotal)
                stepWeight = 0.30 + 0.40 * frac
            } else {
                stepWeight = 0.30
            }
        case .creatingClips:
            // Linear 0.70 → 1.0 across the clip-export run.
            if p.currentClipTotal > 0 {
                let clipFrac = Double(p.currentClipIndex) / Double(p.currentClipTotal)
                stepWeight = 0.70 + 0.30 * clipFrac
            } else {
                stepWeight = 0.70
            }
        case .completed, .noAudio, .noShotsFound, .failed:
            stepWeight = 1.0
        }

        let perVideo = 1.0 / Double(p.total)
        let baseline = Double(max(0, p.currentIndex - 1)) * perVideo
        return min(1.0, baseline + stepWeight * perVideo)
    }

    // MARK: - Completed (summary)

    private func summaryView(_ s: BatchSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: s.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(s.failed == 0 ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Done")
                        .font(.title.bold())
                    Text("\(s.totalClipsCreated) clip\(s.totalClipsCreated == 1 ? "" : "s") created")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 16)

            HStack(spacing: 10) {
                stat("Selected", "\(s.total)")
                stat("Processed", "\(s.processed)")
                if s.failed > 0 {
                    stat("Failed", "\(s.failed)", color: .red)
                }
            }
            .padding(.horizontal)

            List {
                Section("Per video") {
                    ForEach(s.results) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: iconName(for: r.status))
                                    .foregroundStyle(iconColor(for: r.status))
                                Text(r.filename)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(r.clipCount) clip\(r.clipCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let err = r.errorMessage {
                                Text(err)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            } else {
                                Text(r.status.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Failed

    private func failedView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(msg)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.top, 60)
    }

    // MARK: - Helpers

    private func iconName(for s: VideoProcessingStatus) -> String {
        switch s {
        case .completed:    return "checkmark.circle.fill"
        case .noShotsFound: return "circle.dashed"
        case .noAudio:      return "speaker.slash.fill"
        case .failed:       return "xmark.circle.fill"
        default:            return "circle"
        }
    }

    private func iconColor(for s: VideoProcessingStatus) -> Color {
        switch s {
        case .completed:              return .green
        case .noShotsFound, .noAudio: return .orange
        case .failed:                 return .red
        default:                      return .secondary
        }
    }

    private func stat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    VideoAnalysisView(onDone: {}).environmentObject(AppState())
}
