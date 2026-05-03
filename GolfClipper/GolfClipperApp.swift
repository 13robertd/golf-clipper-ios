// GolfClipperApp.swift
// SwiftUI app entry point. Wires up the shared AppState and shows HomeView.
//
// V6 — Watches `scenePhase`. Every time the app becomes `.active`
// (cold launch + every foreground transition), we ask AppState to
// drain anything the NiceShotShare extension dropped into the App
// Group's pending directory while we were away. The import method
// itself no-ops when a batch is already running, so back-to-back
// foreground events are safe.
//
// V6.3 — Local-notification handoff for shares. The Share Extension
// schedules an "Tap to clip" banner after writing its descriptors;
// when the user taps it, iOS foregrounds us, scenePhase fires, and
// the existing import path runs. We:
//   1. Request notification authorization on first launch (silent if
//      already determined; one-shot system prompt otherwise).
//   2. Clear any delivered share-pending banner whenever we foreground —
//      the user is here, the prompt has done its job.

import SwiftUI
import UserNotifications

@main
struct GolfClipperApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(appState)
                .task {
                    await Self.requestNotificationAuthorizationIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        Task { await appState.importPendingSharedVideos() }
                    }
                }
        }
    }

    /// Ask once. If the user already answered (allow or deny), don't
    /// re-prompt. If denied, the share banner just won't fire and the
    /// user opens Nice Shot manually — same as the no-notification
    /// world we had before.
    private static func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .badge])
    }
}
