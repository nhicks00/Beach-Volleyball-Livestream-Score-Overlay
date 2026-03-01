//
//  Constants.swift
//  MultiCourtScore v2
//
//  Design system and application constants
//

import SwiftUI
import AppKit

// MARK: - NSColor Hex Extension

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1.0
        )
    }
}

// MARK: - Design System Colors
enum AppColors {
    // Adaptive color helper — responds to NSApp.appearance changes
    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }

    // Primary brand colors (same in both modes)
    static let primary = Color(hex: "#6366F1")           // Indigo
    static let primaryLight = Color(hex: "#818CF8")
    static let primaryDark = Color(hex: "#4F46E5")

    // Status colors (same in both modes)
    static let success = Color(hex: "#10B981")           // Emerald green
    static let successLight = Color(hex: "#34D399")
    static let warning = Color(hex: "#F59E0B")           // Amber
    static let warningLight = Color(hex: "#FBBF24")
    static let error = Color(hex: "#EF4444")             // Red
    static let errorLight = Color(hex: "#F87171")
    static let info = Color(hex: "#3B82F6")              // Blue

    // Surface colors (adaptive)
    static let background = adaptive(light: "#F5F5F5", dark: "#1E1E1E")
    static let surface = adaptive(light: "#FFFFFF", dark: "#2C2C2C")
    static let surfaceElevated = adaptive(light: "#F0F0F0", dark: "#333333")
    static let surfaceHover = adaptive(light: "#E8E8E8", dark: "#3A3A3A")

    // Sidebar, toolbar, footer backgrounds (adaptive)
    static let sidebarBackground = adaptive(light: "#F0F0F0", dark: "#252525")
    static let toolbarBackground = adaptive(light: "#FFFFFF", dark: "#2C2C2C")
    static let footerBackground = adaptive(light: "#F0F0F0", dark: "#252525")

    // Border color (adaptive)
    static let border = adaptive(light: "#D4D4D8", dark: "#3A3A3A")

    // Text colors (adaptive)
    static let textPrimary = adaptive(light: "#1A1A1A", dark: "#FFFFFF")
    static let textSecondary = adaptive(light: "#52525B", dark: "#A1A1AA")
    static let textMuted = adaptive(light: "#A1A1AA", dark: "#71717A")

    // Status-specific backgrounds (opacity variants — work on both)
    static let liveBackground = Color(hex: "#10B981").opacity(0.15)
    static let waitingBackground = Color(hex: "#F59E0B").opacity(0.15)
    static let finishedBackground = Color(hex: "#3B82F6").opacity(0.15)
    static let idleBackground = adaptive(light: "#E8E8E8", dark: "#3A3A3A").opacity(0.5)
    static let errorBackground = Color(hex: "#EF4444").opacity(0.15)
}

// MARK: - Layout Constants
enum AppLayout {
    static let cornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 16
    static let buttonCornerRadius: CGFloat = 8
    static let smallCornerRadius: CGFloat = 6

    static let cardPadding: CGFloat = 16
    static let sectionPadding: CGFloat = 20
    static let contentPadding: CGFloat = 24

    static let cardSpacing: CGFloat = 16
    static let itemSpacing: CGFloat = 12
    static let smallSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 24

    static let borderWidth: CGFloat = 1.5
    static let iconSize: CGFloat = 18

    // New layout constants
    static let sidebarWidth: CGFloat = 240
    static let statusBarHeight: CGFloat = 28
    static let toolbarHeight: CGFloat = 52
}

// MARK: - Typography
enum AppTypography {
    static let largeTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    static let title = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let headline = Font.system(size: 17, weight: .semibold, design: .default)
    static let body = Font.system(size: 15, weight: .regular, design: .default)
    static let callout = Font.system(size: 14, weight: .medium, design: .default)
    static let caption = Font.system(size: 12, weight: .regular, design: .default)
    static let scoreLarge = Font.system(size: 36, weight: .bold, design: .monospaced)
    static let scoreMedium = Font.system(size: 24, weight: .bold, design: .monospaced)
    static let scoreCompact = Font.system(size: 28, weight: .bold, design: .monospaced)
}

// MARK: - Networking Constants
enum NetworkConstants {
    static let webSocketPort: Int = 8787
    static let pollingInterval: TimeInterval = 1.5
    static let pollingJitterMax: TimeInterval = 0.3
    static let requestTimeout: TimeInterval = 10.0
    static let cacheExpiration: TimeInterval = 1.0
    static let maxRetries: Int = 3
    static let retryDelay: TimeInterval = 1.0
}

// MARK: - App Configuration
enum AppConfig {
    static let maxCourts: Int = 10
    static let maxQueuePreview: Int = 3
    static let holdScoreDuration: TimeInterval = 180 // 3 minutes
    static let staleMatchTimeout: TimeInterval = 900 // 15 minutes of inactivity
    static let appName = "MultiCourtScore"
    static let version = "2.0.0"
}

// MARK: - Overlay Court Names
enum CourtNaming {
    static func displayName(for courtId: Int) -> String {
        if courtId == 1 {
            return "Core 1"
        } else {
            // Mevo cameras: courtId 2 = Mevo 2, courtId 3 = Mevo 3, etc.
            return "Mevo \(courtId)"
        }
    }

    static func shortName(for courtId: Int) -> String {
        if courtId == 1 {
            return "C1"
        } else {
            return "M\(courtId)"
        }
    }
}

// MARK: - Color Extension for Hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
