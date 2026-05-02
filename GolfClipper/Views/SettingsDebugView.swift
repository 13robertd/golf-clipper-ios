// SettingsDebugView.swift
// All the dials. Adjust pre/post-impact seconds, detection preset, and
// minimum spacing. Also shows the most-recent detected impact timestamps
// and a scrollable list of scored candidates so you can decide whether
// the preset needs to be more or less strict.

import SwiftUI

struct SettingsDebugView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: DetectionSettings = .default
    @State private var isReanalysing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Clip length") {
                    Stepper(value: $draft.preImpactSeconds,
                            in: DetectionSettings.preImpactRange,
                            step: 0.1) {
                        HStack {
                            Text("Pre-impact")
                            Spacer()
                            Text("\(draft.preImpactSeconds, specifier: "%.1f") s")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $draft.postImpactSeconds,
                            in: DetectionSettings.postImpactRange,
                            step: 0.1) {
                        HStack {
                            Text("Post-impact")
                            Spacer()
                            Text("\(draft.postImpactSeconds, specifier: "%.1f") s")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Picker("Preset", selection: $draft.preset) {
                        ForEach(DetectionPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(draft.preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Detection sensitivity")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• Catch More — finds more possible swings, but may include extra clips.")
                        Text("• Recommended — fewer false clips. Best for most videos.")
                        Text(" ")
                        Text("If a real swing is missed, use Manual Clip.")
                    }
                    .font(.caption2)
                }

                Section {
                    Stepper(value: $draft.minimumSpacingSeconds,
                            in: DetectionSettings.minSpacingRange,
                            step: 0.5) {
                        HStack {
                            Text("Min. spacing")
                            Spacer()
                            Text("\(draft.minimumSpacingSeconds, specifier: "%.1f") s")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Two impacts closer together than this are merged into one swing. Default is 6.0 s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Re-analyze") {
                    Button {
                        Task {
                            isReanalysing = true
                            app.updateSettings(draft)
                            await app.analyzeAndCreateClips()
                            isReanalysing = false
                        }
                    } label: {
                        if isReanalysing {
                            ProgressView()
                        } else {
                            Label("Re-analyze with these settings",
                                  systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(app.importedVideo == nil || isReanalysing)
                }

                Section("Detected impacts") {
                    if app.lastDetectedTimestamps.isEmpty {
                        Text("None yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(app.lastDetectedTimestamps.enumerated()), id: \.offset) { idx, t in
                            HStack {
                                Text("Swing \(idx + 1)")
                                Spacer()
                                Text(TimeFormatter.mmssTenths(t))
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if app.lastCandidates.isEmpty {
                        Text("Run an analysis to see candidates.")
                            .foregroundStyle(.secondary)
                    } else {
                        // Show top 50 by confidence — accepted first, then rejected.
                        let top = Array(app.lastCandidates
                            .sorted { lhs, rhs in
                                if lhs.accepted != rhs.accepted { return lhs.accepted && !rhs.accepted }
                                return lhs.confidence > rhs.confidence
                            }
                            .prefix(50))
                        ForEach(top) { candidate in
                            CandidateRow(candidate: candidate)
                        }
                    }
                } header: {
                    Text("Candidates (debug)")
                } footer: {
                    Text("Each loud event scored against the preset. Accepted ✓ become clips; ✗ are rejected with the reason.")
                        .font(.caption2)
                }

                Section {
                    Button(role: .destructive) {
                        draft = .default
                    } label: {
                        Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Settings & Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        app.updateSettings(draft)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                draft = app.settings
            }
        }
    }
}

// MARK: - Candidate row

private struct CandidateRow: View {
    let candidate: ImpactCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(TimeFormatter.mmssTenths(candidate.time))
                    .font(.body.monospacedDigit())
                Spacer()
                if candidate.accepted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text(String(format: "conf %.2f", candidate.confidence))
                Text(String(format: "peak %.2f", candidate.peakAmplitude))
                Text(String(format: "PNR %.1f×", candidate.pnr))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let reason = candidate.rejectionReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SettingsDebugView().environmentObject(AppState())
}
