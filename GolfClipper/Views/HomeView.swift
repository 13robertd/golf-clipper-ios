// HomeView.swift
// First screen the user sees. Shows app title, current import status, and
// the main actions: import a video, review clips, manual clip, settings.

import SwiftUI
import PhotosUI

struct HomeView: View {
    @EnvironmentObject var app: AppState

    @State private var pickerItem: PhotosPickerItem?
    @State private var showAnalysis = false
    @State private var showReview = false
    @State private var showManual = false
    @State private var showSettings = false
    // Set true when the analysis sheet finishes; we then auto-present
    // review on its `onDismiss` so SwiftUI doesn't try to stack two sheets.
    @State private var pendingReviewAfterAnalysis = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header

                if let video = app.importedVideo {
                    importedCard(video: video)
                } else {
                    emptyState
                }

                Spacer(minLength: 8)

                primaryActions

                if app.importedVideo != nil {
                    secondaryActions
                }
            }
            .padding()
            .navigationTitle("Golf Clipper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .onChange(of: pickerItem) { _, newItem in
                guard let newItem else { return }
                showAnalysis = true
                Task {
                    await app.importPickedItem(newItem)
                    pickerItem = nil
                }
            }
            .sheet(isPresented: $showAnalysis,
                   onDismiss: {
                       // Trigger review presentation only AFTER analysis sheet
                       // is fully dismissed — avoids SwiftUI's sheet-stacking
                       // race where the second sheet silently fails to present.
                       if pendingReviewAfterAnalysis {
                           pendingReviewAfterAnalysis = false
                           if !app.clips.isEmpty {
                               showReview = true
                           }
                       }
                   }) {
                VideoAnalysisView(onDone: {
                    pendingReviewAfterAnalysis = !app.clips.isEmpty
                    showAnalysis = false
                })
            }
            .sheet(isPresented: $showReview) {
                ClipReviewView()
            }
            .sheet(isPresented: $showManual) {
                if let video = app.importedVideo {
                    ManualClipView(video: video)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsDebugView()
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { app.errorMessage != nil },
                                        set: { if !$0 { app.errorMessage = nil } })) {
                Button("OK", role: .cancel) { app.errorMessage = nil }
            } message: {
                Text(app.errorMessage ?? "")
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "scissors")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.green)
            Text("Golf Clipper")
                .font(.largeTitle.bold())
            Text("Import a golf video and we'll split it into individual swing clips.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.horizontal)
        }
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No video imported yet")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func importedCard(video: ImportedVideo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill").foregroundStyle(.green)
                Text(video.originalFilename)
                    .font(.headline).lineLimit(1)
            }
            HStack {
                Label(TimeFormatter.mmss(video.duration), systemImage: "clock")
                Spacer()
                Label("\(app.clips.count) clips", systemImage: "scissors")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var primaryActions: some View {
        VStack(spacing: 12) {
            // Use a PhotosPicker directly so the system permission UX is clean.
            PhotosPicker(selection: $pickerItem,
                         matching: .videos,
                         photoLibrary: .shared()) {
                Label(app.importedVideo == nil ? "Import Video" : "Import a Different Video",
                      systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: 10) {
            Button {
                showReview = true
            } label: {
                Label("Review Clips (\(app.clips.count))",
                      systemImage: "rectangle.stack.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button {
                showManual = true
            } label: {
                Label("Manual Clip", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                app.deleteAllClipsAndVideo()
            } label: {
                Label("Clear Imported Video", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .foregroundStyle(.red)
        }
    }
}

#Preview {
    HomeView().environmentObject(AppState())
}
