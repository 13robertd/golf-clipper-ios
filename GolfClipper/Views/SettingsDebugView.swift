// SettingsDebugView.swift
// All the dials. V3 surfaces the energy-ratio detector's diagnostics so
// detection can be tuned with real numbers (median ratio, adaptive
// threshold, dedup counts, processing time) instead of guessing.

import SwiftUI

struct SettingsDebugView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: DetectionSettings = .default
    @State private var isReanalysing = false

    var body: some View {
        NavigationStack {
            Form {
                clipLengthSection
                presetSection
                multiplierSection
                spacingSection
                motionValidationSection
                reanalyzeSection
                statsSection
                detectedSection
                motionScoresSection
                candidatesSection
                resetSection
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
            .onAppear { draft = app.settings }
        }
    }

    // MARK: - Sections

    private var clipLengthSection: some View {
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
    }

    private var presetSection: some View {
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
                Text("• Catch More — finds more possible shots, but may include extra clips.")
                Text("• Recommended — fewer false clips. Best for most videos.")
                Text(" ")
                Text("If a real shot is missed, use Manual Clip.")
            }
            .font(.caption2)
        }
    }

    /// V3 — manual override of the adaptive-threshold multiplier.
    /// Higher = stricter. nil = use the preset's default.
    private var multiplierSection: some View {
        Section {
            HStack {
                Text("Multiplier (N)")
                Spacer()
                Text(String(format: "%.2f",
                            draft.detectionMultiplierOverride ?? draft.preset.detectionMultiplier))
                    .foregroundStyle(.secondary)
                    .font(.body.monospacedDigit())
            }
            Slider(value: Binding(
                get: { draft.detectionMultiplierOverride ?? draft.preset.detectionMultiplier },
                set: { draft.detectionMultiplierOverride = $0 }
            ), in: DetectionSettings.multiplierRange, step: 0.05)

            if draft.detectionMultiplierOverride != nil {
                Button("Use preset default (\(String(format: "%.2f", draft.preset.detectionMultiplier)))") {
                    draft.detectionMultiplierOverride = nil
                }
                .font(.caption)
            }
        } header: {
            Text("Threshold multiplier")
        } footer: {
            Text("threshold = median(ratio) + N × stddev(ratio). Higher N = fewer detections. Defaults: Catch More 2.0, Recommended 2.5.")
                .font(.caption2)
        }
    }

    private var spacingSection: some View {
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
            Text("Two impacts closer together than this are merged into one shot. Default is 6.0 s.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// V3.6 — toggle + ratio threshold for the motion-validation pass.
    private var motionValidationSection: some View {
        Section {
            Toggle("Motion validation", isOn: $draft.motionValidationEnabled)

            if draft.motionValidationEnabled {
                HStack {
                    Text("Speed-spike ratio")
                    Spacer()
                    Text(String(format: "%.1f×", draft.motionThreshold))
                        .foregroundStyle(.secondary)
                        .font(.body.monospacedDigit())
                }
                Slider(value: $draft.motionThreshold,
                       in: DetectionSettings.motionThresholdRange,
                       step: 0.1)
                Text("How sharp the motion spike must be. 3× = peak frame change is at least 3 times the quietest. Lower to 2× if real swings are being rejected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Motion validation")
        } footer: {
            Text("Audio finds candidates; motion confirms them. A real swing is the fastest motion in a 3-second window — walking and waggling are too slow to spike.")
                .font(.caption2)
        }
    }

    private var reanalyzeSection: some View {
        Section("Re-analyze") {
            Button {
                Task {
                    isReanalysing = true
                    app.updateSettings(draft)
                    await app.reanalyzeAllVideos()
                    isReanalysing = false
                }
            } label: {
                if isReanalysing {
                    ProgressView()
                } else {
                    Label("Re-analyze all videos with these settings",
                          systemImage: "arrow.clockwise")
                }
            }
            .disabled(app.importedVideos.isEmpty || isReanalysing)
        }
    }

    /// V3 — diagnostic stats from the most recent detection run.
    private var statsSection: some View {
        Section {
            if let s = app.lastDetectionStats {
                statRow("Video duration",  String(format: "%.2f s", s.videoDurationSeconds))
                statRow("Windows analyzed", "\(s.totalWindowsAnalyzed)")
                statRow("Noise floor (median ratio)", String(format: "%.3f", s.medianRatio))
                statRow("Stddev (ratio)", String(format: "%.3f", s.stddevRatio))
                statRow("Multiplier (N)", String(format: "%.2f", s.multiplier))
                statRow("Adaptive threshold", String(format: "%.3f", s.adaptiveThreshold))
                statRow("Raw peaks", "\(s.rawPeakCount)")
                statRow("After 500 ms dedup", "\(s.after500msDedup)")
                statRow("Final impacts", "\(s.afterMinSpacing)")
                statRow("Processing time", String(format: "%.2f s", s.processingTimeSeconds))
            } else {
                Text("Run an analysis to see stats.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Detection stats")
        } footer: {
            Text("From the most-recent video analyzed.")
                .font(.caption2)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var detectedSection: some View {
        Section("Detected impacts") {
            if app.lastDetectedTimestamps.isEmpty {
                Text("None yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(app.lastDetectedTimestamps.enumerated()), id: \.offset) { idx, t in
                    HStack {
                        Text("Shot \(idx + 1)")
                        Spacer()
                        Text(TimeFormatter.mmssTenths(t))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// V3.6 — per-candidate motion profile + ratio from the most-recent run.
    private var motionScoresSection: some View {
        Section {
            if app.lastMotionValidations.isEmpty {
                Text("Run an analysis with motion validation on to see scores.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.lastMotionValidations.sorted { $0.time < $1.time }) { v in
                    MotionScoreRow(validation: v)
                }
            }
        } header: {
            Text("Motion profiles")
        } footer: {
            Text("Each candidate's 6-interval motion profile across the 3-second window around impact. Confirmed = sharp spike (high peak/min ratio) with the peak in the swing window (intervals 3–5).")
                .font(.caption2)
        }
    }

    private var candidatesSection: some View {
        Section {
            if app.lastCandidates.isEmpty {
                Text("Run an analysis to see candidates.")
                    .foregroundStyle(.secondary)
            } else {
                // Accepted first, then strongest rejections.
                let top = Array(app.lastCandidates
                    .sorted { lhs, rhs in
                        if lhs.accepted != rhs.accepted { return lhs.accepted && !rhs.accepted }
                        return lhs.energyRatio > rhs.energyRatio
                    }
                    .prefix(50))
                ForEach(top) { candidate in
                    CandidateRow(candidate: candidate)
                }
            }
        } header: {
            Text("Candidates (debug)")
        } footer: {
            Text("Each loud event scored against the adaptive threshold. Accepted ✓ become clips; ✗ are rejected with the reason.")
                .font(.caption2)
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                draft = .default
            } label: {
                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
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
                Text(String(format: "ratio %.2f×", candidate.energyRatio))
                Text(String(format: "rms %.3f", candidate.rms))
                Text(String(format: "thr %.2f", candidate.threshold))
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

// MARK: - Motion score row

private struct MotionScoreRow: View {
    let validation: MotionValidation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(TimeFormatter.mmssTenths(validation.time))
                    .font(.body.monospacedDigit())
                Spacer()
                if validation.peakIntervalIndex > 0 {
                    Text(String(format: "%.1f×", validation.peakRatio))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("peak@\(validation.peakIntervalIndex)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if validation.confirmed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            if !validation.motionProfile.isEmpty {
                Text(profileText(validation.motionProfile))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let reason = validation.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(validation.confirmed ? Color.secondary : Color.orange)
            }
        }
    }

    private func profileText(_ profile: [Double]) -> String {
        "[" + profile.map { String(format: "%.2f", $0) }.joined(separator: ", ") + "]"
    }
}

#Preview {
    SettingsDebugView().environmentObject(AppState())
}
