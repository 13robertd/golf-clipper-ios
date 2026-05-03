// ActionButtonStyles.swift
// V4 — Unified action language across the app. Every user action falls
// into one of three tiers, each with a fixed visual style so the stakes
// are obvious at a glance:
//
//   Tier 1 — RemoveAction         App-level only. Gray text link, no icon,
//                                 no background, no confirmation.
//                                 Examples: "Remove Clip", "Remove from Queue".
//
//   Tier 2 — SaveAction           Photos save (additive). Green filled
//                                 button with share icon, semibold.
//                                 Examples: "Save to Photos", "Save All to Photos".
//
//   Tier 3 — DeleteFromPhotosAction  Permanent Photos deletion. Red
//                                 outlined (NEVER filled) with trash icon.
//                                 The label MUST always include
//                                 "from Photos" — never bare "Delete".
//                                 Apple's PHPhotoLibrary system dialog is
//                                 the only confirmation; do not add custom
//                                 confirmation alerts on top of these.
//
// Apply via:
//   .buttonStyle(.removeAction)
//   .buttonStyle(.saveAction)
//   .buttonStyle(.deleteFromPhotosAction)
//
// The label content is the caller's responsibility — these styles only
// own chrome (background, color, font weight, padding). For the canonical
// icons see ActionIcon below.

import SwiftUI

/// Canonical SF Symbols for each tier. Use these instead of hard-coding
/// system names in callers so the icon stays consistent everywhere.
enum ActionIcon {
    /// Tier 2 — Save to Photos. Apple's standard share/upload glyph.
    static let save = "square.and.arrow.up"
    /// Tier 3 — Delete from Photos. Always paired with red outlined style.
    static let deleteFromPhotos = "trash"
}

// MARK: - Tier 1: Remove (app-level)

struct RemoveActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(.secondary)
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

extension ButtonStyle where Self == RemoveActionStyle {
    static var removeAction: RemoveActionStyle { .init() }
}

// MARK: - Tier 2: Save to Photos

struct SaveActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.green.opacity(configuration.isPressed ? 0.85 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension ButtonStyle where Self == SaveActionStyle {
    static var saveAction: SaveActionStyle { .init() }
}

// MARK: - Tier 3: Delete from Photos (permanent)

struct DeleteFromPhotosActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.red, lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

extension ButtonStyle where Self == DeleteFromPhotosActionStyle {
    static var deleteFromPhotosAction: DeleteFromPhotosActionStyle { .init() }
}
