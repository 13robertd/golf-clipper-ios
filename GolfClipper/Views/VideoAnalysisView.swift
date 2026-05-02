// VideoAnalysisView.swift
// Modal sheet that shows the user what the app is doing while it imports,
// analyzes audio, detects swings, and exports clips.

import SwiftUI

struct VideoAnalysisView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps the final "Continue" button (after Done or Failed).
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            statusIcon
                .font(.system(size: 56))
                .foregroundStyle(iconColor)

            Text(app.analysis.statusText.isEmpty
                 ? "Preparing…" : app.analysis.statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if app.analysis.isWorking {
                ProgressView(value: workingProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)
            }

            if case .completed(let n) = app.analysis {
                Text("\(n) swing\(n == 1 ? "" : "s") detected")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !app.analysis.isWorking {
                Button {
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
            }
        }
        .padding(.bottom, 24)
        .interactiveDismissDisabled(app.analysis.isWorking)
    }

    private var statusIcon: Image {
        switch app.analysis {
        case .importing, .analyzing, .creatingClips: return Image(systemName: "waveform")
        case .completed: return Image(systemName: "checkmark.circle.fill")
        case .failed:    return Image(systemName: "exclamationmark.triangle.fill")
        case .idle:      return Image(systemName: "tray")
        }
    }

    private var iconColor: Color {
        switch app.analysis {
        case .completed: return .green
        case .failed:    return .orange
        default:         return .blue
        }
    }

    private var workingProgress: Double {
        switch app.analysis {
        case .importing: return 0.05
        case .analyzing(let p): return 0.1 + p * 0.6
        case .creatingClips(let d, let t): return 0.7 + (Double(d) / max(1, Double(t))) * 0.3
        default: return 1.0
        }
    }
}

#Preview {
    VideoAnalysisView(onDone: {}).environmentObject(AppState())
}
