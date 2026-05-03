// ManualClipFlow.swift
// Wrapper sheet for the Manual Clip flow.
//
// V1.5 needs to handle three cases cleanly:
//   • 0 imported videos → show a friendly empty state
//   • 1 imported video  → land directly on ManualClipView (no extra tap)
//   • 2+ imported videos → show a picker; tapping a row pushes the clipper
//
// Owns the NavigationStack and the Done toolbar button. The pushed
// ManualClipView is therefore minimal — just title + content + observers.

import SwiftUI

struct ManualClipFlow: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.importedVideos.isEmpty {
            emptyState
                .navigationTitle("Manual Clip")
        } else if app.importedVideos.count == 1, let only = app.importedVideos.first {
            ManualClipView(video: only)
        } else {
            videoPicker
                .navigationTitle("Pick a video")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Import a video first")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var videoPicker: some View {
        List(app.importedVideos) { video in
            NavigationLink {
                ManualClipView(video: video)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "video.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        // V5 — displayName, not the raw originalFilename.
                        Text(video.displayName)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(TimeFormatter.mmss(video.duration))
                            let n = app.clips.filter { $0.sourceVideoId == video.id }.count
                            Text("·")
                            Text("\(n) clip\(n == 1 ? "" : "s")")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    ManualClipFlow().environmentObject(AppState())
}
