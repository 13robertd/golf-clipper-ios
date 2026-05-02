// GolfClipperApp.swift
// SwiftUI app entry point. Wires up the shared AppState and shows HomeView.

import SwiftUI

@main
struct GolfClipperApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(appState)
        }
    }
}
