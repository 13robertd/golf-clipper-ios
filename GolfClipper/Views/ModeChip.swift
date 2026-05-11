// ModeChip.swift
// V4.1 — Small capsule control that surfaces a video's current
// DetectionMode and lets the user override it. Placed inline in
// ClipReviewView's section header (per-video) and in
// SourceVideoPreviewView's metadata section.
//
// Visual: capsule with the mode's SF symbol + label, green tint.
// Tap → caller presents a confirmation dialog; on confirm the caller
// kicks off `AppState.reanalyzeVideo`. During re-analysis the chip
// renders a small ProgressView in place of the label and is disabled.

import SwiftUI

struct ModeChip: View {
    let mode: DetectionMode
    let isReanalyzing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if isReanalyzing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.green)
                } else {
                    Image(systemName: mode.symbolName)
                        .font(.caption2.weight(.semibold))
                    Text(mode.displayName)
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isReanalyzing)
        .accessibilityLabel("Detection mode: \(mode.displayName)")
        .accessibilityHint("Double-tap to switch to \(mode.opposite.displayName) and re-analyze")
    }
}

#Preview {
    VStack(spacing: 16) {
        ModeChip(mode: .singleSwing, isReanalyzing: false, onTap: {})
        ModeChip(mode: .rangeSession, isReanalyzing: false, onTap: {})
        ModeChip(mode: .rangeSession, isReanalyzing: true, onTap: {})
    }
    .padding()
}
