// PhotosPermissionView.swift
// Shown by CustomVideoBrowserView when Photos access is denied or
// restricted. The "Open Settings" button deep-links to this app's
// privacy panel so the user can flip the toggle in one tap.

import SwiftUI
import Photos
import UIKit

struct PhotosPermissionView: View {
    let status: PHAuthorizationStatus
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button(action: openSettings) {
                Text("Open Settings")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button("Cancel") { onCancel() }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var title: String {
        switch status {
        case .denied, .restricted: return "Photos Access Denied"
        default:                   return "Photos Access Needed"
        }
    }

    private var message: String {
        "Nice Shot needs access to your Photos to import videos."
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
