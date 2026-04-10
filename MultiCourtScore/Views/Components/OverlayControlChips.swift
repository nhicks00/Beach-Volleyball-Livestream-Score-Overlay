//
//  OverlayControlChips.swift
//  MultiCourtScore v2
//
//  Shared high-contrast control chips for overlay/layout menus.
//

import SwiftUI

enum OverlayControlDisplay {
    static func layout(_ value: String?) -> String {
        switch value {
        case "center": return "Center"
        case "top-left": return "Top-Left"
        case "bottom-left": return "Bottom-Left"
        default: return "Default"
        }
    }

    static func bubbleOverride(_ value: Bool?) -> String {
        switch value {
        case true: return "Show"
        case false: return "Hide"
        case nil: return "Default"
        }
    }

    static func toggleOverride(_ value: Bool?) -> String {
        switch value {
        case true: return "Enable"
        case false: return "Disable"
        case nil: return "Default"
        }
    }

    static func broadcastPreview(_ value: String?) -> String {
        switch value {
        case "countdown": return "Countdown"
        case "status": return "Match Soon"
        default: return "Default"
        }
    }
}

struct OverlayMenuChip: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppColors.textMuted)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(AppColors.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 156, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColors.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct OverlayActionChip: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(isDisabled ? AppColors.textMuted : AppColors.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.surfaceElevated.opacity(isDisabled ? 0.7 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppColors.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
