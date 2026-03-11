//
//  DashboardView.swift
//  MultiCourtScore v2
//
//  Main dashboard with dark theme, inline toolbar, adaptive grid, and status bar
//

import SwiftUI

// MARK: - Court Filter

enum CourtFilter: String, CaseIterable {
    case all = "All"
    case live = "Live"
    case waiting = "Waiting"
    case idle = "Idle"

    func matches(_ court: Court) -> Bool {
        switch self {
        case .all: return true
        case .live: return court.status == .live
        case .waiting: return court.status == .waiting
        case .idle: return court.status == .idle
        }
    }
}

func dashboardCourtStatusCounts(for courts: [Court]) -> [CourtFilter: Int] {
    [
        .all: courts.count,
        .live: courts.filter { $0.status == .live }.count,
        .waiting: courts.filter { $0.status == .waiting }.count,
        .idle: courts.filter { $0.status == .idle }.count
    ]
}

func dashboardSupplementalStatusCounts(for courts: [Court]) -> (finished: Int, offline: Int) {
    (
        finished: courts.filter { $0.status == .finished }.count,
        offline: courts.filter { $0.status == .error }.count
    )
}

enum DashboardTab: String, CaseIterable {
    case courts = "Courts"
    case changes = "Change Log"
}

struct EditorConfig: Identifiable {
    let id: Int
}

enum DashboardHealthBannerTone: Equatable {
    case warning
    case error

    var color: Color {
        switch self {
        case .warning:
            return AppColors.warning
        case .error:
            return AppColors.error
        }
    }
}

struct DashboardHealthBannerModel: Equatable {
    let message: String
    let tone: DashboardHealthBannerTone
    let systemImageName: String

    var color: Color {
        tone.color
    }
}

func formatOverlayHealthUptime(_ seconds: Int) -> String {
    guard seconds > 0 else { return "0m" }

    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60

    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }

    if minutes > 0 {
        return "\(minutes)m"
    }

    return "\(max(1, seconds))s"
}

func dashboardHealthStatusText(for health: OverlayHealthSnapshot) -> String {
    if let startupError = health.startupError, !startupError.isEmpty {
        return startupError
    }
    if !health.errorCourtIds.isEmpty {
        return "Degraded: error courts \(health.errorCourtIds.map(String.init).joined(separator: ", "))"
    }
    if !health.stalePollingCourtIds.isEmpty {
        return "Degraded: stale courts \(health.stalePollingCourtIds.map(String.init).joined(separator: ", "))"
    }
    return "localhost:\(String(health.port))"
}

func dashboardHealthRuntimeSummary(for health: OverlayHealthSnapshot) -> String? {
    var parts: [String] = []

    if health.uptime > 0 {
        parts.append("up \(formatOverlayHealthUptime(health.uptime))")
    }

    if health.watchdogRestartCount > 0 {
        parts.append("watchdog \(health.watchdogRestartCount)x")
    }

    if health.signalRMutationFallbackCount > 0 {
        parts.append("signalR fallback \(health.signalRMutationFallbackCount)x")
    }

    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "  |  ")
}

func makeDashboardHealthBannerModel(
    health: OverlayHealthSnapshot,
    signalREnabled: Bool,
    signalRStatus: SignalRStatus
) -> DashboardHealthBannerModel? {
    if let startupError = health.startupError, !startupError.isEmpty {
        return DashboardHealthBannerModel(
            message: "Overlay server unavailable. \(startupError)",
            tone: .error,
            systemImageName: "exclamationmark.octagon.fill"
        )
    }

    if !health.errorCourtIds.isEmpty {
        return DashboardHealthBannerModel(
            message: "Polling failed on court\(health.errorCourtIds.count == 1 ? "" : "s") \(health.errorCourtIds.map(String.init).joined(separator: ", ")).",
            tone: .error,
            systemImageName: "exclamationmark.octagon.fill"
        )
    }

    if !health.stalePollingCourtIds.isEmpty {
        return DashboardHealthBannerModel(
            message: "Polling is stale on court\(health.stalePollingCourtIds.count == 1 ? "" : "s") \(health.stalePollingCourtIds.map(String.init).joined(separator: ", ")).",
            tone: .warning,
            systemImageName: "exclamationmark.triangle.fill"
        )
    }

    if !health.signalRMutationFallbackCourts.isEmpty {
        return DashboardHealthBannerModel(
            message: "SignalR mutation stream is quiet. Polling fallback active on court\(health.signalRMutationFallbackCourts.count == 1 ? "" : "s") \(health.signalRMutationFallbackCourts.map(String.init).joined(separator: ", ")).",
            tone: .warning,
            systemImageName: "antenna.radiowaves.left.and.right"
        )
    }

    if signalREnabled {
        switch signalRStatus {
        case .failed(let reason):
            return DashboardHealthBannerModel(
                message: "SignalR disconnected. Polling continues. \(reason)",
                tone: .warning,
                systemImageName: "exclamationmark.triangle.fill"
            )
        case .noCredentials:
            return DashboardHealthBannerModel(
                message: "SignalR is enabled but credentials are missing. Polling continues.",
                tone: .warning,
                systemImageName: "exclamationmark.triangle.fill"
            )
        default:
            break
        }
    }

    return nil
}

struct DashboardView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    private let runtimeLog = RuntimeLogStore.shared

    // State
    @State private var renamingCourtId: Int?
    @State private var newCourtName = ""
    @State private var showClearAllConfirmation = false
    @State private var urlCopiedCourtId: Int?

    // Modal state
    @State private var showScannerModal = false
    @State private var showSettingsModal = false
    @State private var editorConfig: EditorConfig?

    // Filter
    @State private var courtFilter: CourtFilter = .all
    @State private var selectedTab: DashboardTab = .courts

    private var filteredCourts: [Court] {
        appViewModel.courts.filter { courtFilter.matches($0) }
    }

    private var courtStatusCounts: [CourtFilter: Int] {
        dashboardCourtStatusCounts(for: appViewModel.courts)
    }

    private var supplementalStatusCounts: (finished: Int, offline: Int) {
        dashboardSupplementalStatusCounts(for: appViewModel.courts)
    }

    private var overlayHealthSnapshot: OverlayHealthSnapshot {
        WebSocketHub.shared.currentHealthSnapshot(port: appViewModel.appSettings.serverPort)
    }

    private var dashboardHealthBannerModel: DashboardHealthBannerModel? {
        makeDashboardHealthBannerModel(
            health: overlayHealthSnapshot,
            signalREnabled: appViewModel.appSettings.signalREnabled,
            signalRStatus: appViewModel.signalRStatus
        )
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()
            
            GeometryReader { rootGeo in
                VStack(spacing: 0) {
                    // Toolbar header
                    toolbar(for: rootGeo.size.width)

                    if let banner = dashboardHealthBannerModel {
                        dashboardHealthBanner(banner, health: overlayHealthSnapshot)
                    }

                    // Courts grid
                    if selectedTab == .courts {
                        GeometryReader { geometry in
                            let columnCount = dashboardColumnCount(for: geometry.size.width)
                            let columns = dashboardColumns(columnCount: columnCount)
                            let cardHeight = dashboardCardHeight(
                                containerHeight: geometry.size.height,
                                columnCount: columnCount,
                                itemCount: filteredCourts.count
                            )
                            
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: AppLayout.cardSpacing) {
                                    ForEach(filteredCourts) { court in
                                        CourtCard(
                                            court: court,
                                            operationalHealth: appViewModel.currentCourtOperationalHealth(for: court.id),
                                            onStart: { appViewModel.startPolling(for: court.id) },
                                            onStop: { appViewModel.stopPolling(for: court.id) },
                                            onSkipNext: { appViewModel.skipToNext(court.id) },
                                            onSkipPrevious: { appViewModel.skipToPrevious(court.id) },
                                            onEditQueue: { openQueueEditor(for: court.id) },
                                            onRename: {
                                                renamingCourtId = court.id
                                                newCourtName = court.name
                                            },
                                            onCopyURL: { copyOverlayURL(for: court.id) },
                                            onSetLayout: { layout in appViewModel.setScoreboardLayout(court.id, layout: layout) },
                                            isCopied: urlCopiedCourtId == court.id,
                                            holdScoreDuration: appViewModel.appSettings.holdScoreDuration
                                        )
                                        .frame(maxWidth: .infinity)
                                        .frame(height: cardHeight)
                                    }
                                }
                                .padding(.horizontal, AppLayout.contentPadding)
                                .padding(.vertical, AppLayout.cardSpacing)
                            }
                        }
                    } else {
                        ChangeLogView()
                    }

                    // Status bar footer
                    statusBar
                }
            }
            
            // Queue Editor Overlay
            if let config = editorConfig {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                
                GeometryReader { geo in
                    QueueEditorView(courtId: config.id, onDismiss: {
                            closeQueueEditor(reason: "dismissed")
                        })
                        .environmentObject(appViewModel)
                        .frame(
                            width: min(max(geo.size.width * 0.85, 900), 1400),
                            height: min(max(geo.size.height * 0.85, 500), 900)
                        )
                        .background(AppColors.background)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.5), radius: 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }

            if showScannerModal {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeScannerModal(reason: "backdrop")
                    }

                GeometryReader { geo in
                    ScanWorkflowView(onClose: { reason in
                        closeScannerModal(reason: reason)
                    })
                    .environmentObject(appViewModel)
                    .frame(
                        width: min(max(geo.size.width * 0.92, 980), 1700),
                        height: min(max(geo.size.height * 0.92, 700), 1140)
                    )
                    .background(AppColors.background)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.55), radius: 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }

            if showSettingsModal {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeSettingsModal(reason: "backdrop")
                    }

                GeometryReader { geo in
                    SettingsView(onClose: { reason in
                        closeSettingsModal(reason: reason)
                    })
                    .environmentObject(appViewModel)
                    .frame(
                        width: min(max(geo.size.width * 0.62, 680), 1080),
                        height: min(max(geo.size.height * 0.72, 520), 860)
                    )
                    .background(AppColors.background)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.45), radius: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .animation(
            .easeInOut(duration: 0.2),
            value: editorConfig != nil || showScannerModal || showSettingsModal
        )
        .onReceive(NotificationCenter.default.publisher(for: DashboardCommand.openScanner)) { _ in
            openScannerModal()
        }
        .onReceive(NotificationCenter.default.publisher(for: DashboardCommand.openSettings)) { _ in
            openSettingsModal()
        }
        .onReceive(NotificationCenter.default.publisher(for: DashboardCommand.confirmClearAll)) { _ in
            openClearAllConfirmation()
        }
        .accessibilityIdentifier("dashboard.root")
        // Rename Alert
        .alert("Rename Overlay", isPresented: Binding(
            get: { renamingCourtId != nil },
            set: { if !$0 { renamingCourtId = nil } }
        )) {
            TextField("New name", text: $newCourtName)
            Button("Cancel", role: .cancel) { renamingCourtId = nil }
            Button("Save") {
                if let id = renamingCourtId {
                    appViewModel.renameCourt(id, to: newCourtName)
                }
                renamingCourtId = nil
            }
        } message: {
            Text("Enter a new name for this overlay")
        }
        // Clear All Confirmation
        .alert("Clear All Queues?", isPresented: $showClearAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                appViewModel.clearAllQueues()
            }
        } message: {
            Text("This will stop all polling and remove every match from all \(appViewModel.courts.count) court queues. This cannot be undone.")
        }
    }

    // MARK: - Toolbar
    
    @ViewBuilder
    private func toolbar(for width: CGFloat) -> some View {
        if width < 1320 {
            compactToolbar
        } else {
            regularToolbar
        }
    }
    
    private var regularToolbar: some View {
        HStack(spacing: 16) {
            // Left: App name
            Text(AppConfig.appName)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            Spacer()

            // Center: Filter segmented control
            Picker("View", selection: $selectedTab) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            if selectedTab == .courts {
                filterPicker
            }

            Spacer()

            // Right: Actions
            HStack(spacing: 8) {
                Button { appViewModel.startAllPolling() } label: {
                    Label("Start All", systemImage: "play.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityIdentifier("toolbar.startAll")
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(AppColors.success)

                Button { appViewModel.stopAllPolling() } label: {
                    Label("Stop All", systemImage: "stop.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityIdentifier("toolbar.stopAll")
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(AppColors.error)

                Divider()
                    .frame(height: 24)

                Button {
                    openScannerModal()
                } label: {
                    Label("Scan VBL", systemImage: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityIdentifier("toolbar.scan")
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(AppColors.primary)

                Button(role: .destructive) {
                    openClearAllConfirmation()
                } label: {
                    Label("Clear All", systemImage: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityIdentifier("toolbar.clearAll")
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    openSettingsModal()
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                }
                .accessibilityIdentifier("toolbar.settings")
                .buttonStyle(.borderless)
                .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(.horizontal, AppLayout.contentPadding)
        .padding(.vertical, 14)
        .frame(minHeight: AppLayout.toolbarHeight)
        .background(AppColors.toolbarBackground)
        .overlay(
            Divider().overlay(AppColors.border),
            alignment: .bottom
        )
    }
    
    private var compactToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(AppConfig.appName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button { appViewModel.startAllPolling() } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .accessibilityIdentifier("toolbar.startAll")
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(AppColors.success)
                    .help("Start All")

                    Button { appViewModel.stopAllPolling() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .accessibilityIdentifier("toolbar.stopAll")
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(AppColors.error)
                    .help("Stop All")

                    Button {
                        openScannerModal()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .accessibilityIdentifier("toolbar.scan")
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(AppColors.primary)
                    .help("Scan VBL")

                    Button(role: .destructive) {
                        openClearAllConfirmation()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .accessibilityIdentifier("toolbar.clearAll")
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Clear All")

                    Button {
                        openSettingsModal()
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .accessibilityIdentifier("toolbar.settings")
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Settings")
                }
            }
            .padding(.horizontal, AppLayout.contentPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Picker("View", selection: $selectedTab) {
                        ForEach(DashboardTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)

                    if selectedTab == .courts {
                        filterPicker
                    }
                }
                .padding(.horizontal, AppLayout.contentPadding)
            }
        }
        .padding(.vertical, 14)
        .frame(minHeight: AppLayout.toolbarHeight)
        .background(AppColors.toolbarBackground)
        .overlay(
            Divider().overlay(AppColors.border),
            alignment: .bottom
        )
    }

    // MARK: - Filter Picker

    private var filterPicker: some View {
        HStack(spacing: 0) {
            ForEach(CourtFilter.allCases, id: \.self) { filter in
                let count = courtStatusCounts[filter] ?? 0
                let isSelected = courtFilter == filter

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        courtFilter = filter
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(filter.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)

                        if filter != .all {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(isSelected ? AppColors.textPrimary : AppColors.textMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.white.opacity(0.15) : AppColors.surfaceHover)
                                )
                        }
                    }
                    .foregroundColor(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? AppColors.surfaceHover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.surface)
        )
    }

    // MARK: - Status Bar

    private func dashboardHealthBanner(_ banner: DashboardHealthBannerModel, health: OverlayHealthSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: banner.systemImageName)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(banner.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(2)

                if let runtimeSummary = dashboardHealthRuntimeSummary(for: health) {
                    Text(runtimeSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AppColors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if dashboardHealthBannerCanRetry {
                Button("Retry") {
                    appViewModel.retryServicesRestoringPollingIfConfigured()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(banner.color)
                .accessibilityIdentifier("dashboard.healthBanner.retry")
            }

            Button("Export") {
                exportDiagnosticsBundleAndCopySummaryFromBanner()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(banner.color)
            .accessibilityIdentifier("dashboard.healthBanner.export")

            Button("Details") {
                openSettingsModal()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(banner.color)
        }
        .padding(.horizontal, AppLayout.contentPadding)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(banner.color.opacity(0.10))
        )
        .overlay(
            Rectangle()
                .fill(banner.color.opacity(0.35))
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityIdentifier("dashboard.healthBanner")
    }

    private var dashboardHealthBannerCanRetry: Bool {
        if let startupError = overlayHealthSnapshot.startupError, !startupError.isEmpty {
            return true
        }

        return overlayHealthSnapshot.serverStatus != "running"
    }

    private func exportDiagnosticsBundleAndCopySummaryFromBanner() {
        #if os(macOS)
        do {
            let destinationURL = try appViewModel.exportDiagnosticsBundleToDefaultLocation(runtimeLog: runtimeLog)
            let summary = appViewModel.supportSummaryText(runtimeLog: runtimeLog)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary, forType: .string)
            runtimeLog.log(.info, subsystem: "operator", message: "exported diagnostics bundle from dashboard health banner to \(destinationURL.lastPathComponent)")
            runtimeLog.log(.info, subsystem: "operator", message: "copied support summary from dashboard health banner")
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            runtimeLog.log(.warning, subsystem: "operator", message: "dashboard health banner diagnostics export failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Diagnostics export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        #endif
    }

    private var statusBar: some View {
        let health = overlayHealthSnapshot
        let healthColor: Color = {
            if health.status == "ok" {
                return AppColors.success
            }
            return health.serverStatus == "running" ? AppColors.warning : AppColors.error
        }()
        let healthText = dashboardHealthStatusText(for: health)
        let healthRuntimeSummary = dashboardHealthRuntimeSummary(for: health)

        return HStack(spacing: 16) {
            Text("v\(AppConfig.version)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColors.textMuted)

            Divider()
                .frame(height: 12)

            let liveCount = appViewModel.courts.filter { $0.status == .live }.count
            let remainingMatches = appViewModel.courts.reduce(0) { total, court in
                guard let active = court.activeIndex else { return total }
                return total + max(0, court.queue.count - active)
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(liveCount > 0 ? AppColors.success : AppColors.textMuted)
                    .frame(width: 6, height: 6)
                Text("\(liveCount) live")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textMuted)
            }

            Text("\(remainingMatches) remaining")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textMuted)

            if supplementalStatusCounts.finished > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(AppColors.info)
                        .frame(width: 6, height: 6)
                    Text("\(supplementalStatusCounts.finished) finished")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textMuted)
                }
            }

            if supplementalStatusCounts.offline > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(AppColors.error)
                        .frame(width: 6, height: 6)
                    Text("\(supplementalStatusCounts.offline) offline")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textMuted)
                }
            }

            if appViewModel.appSettings.signalREnabled {
                Divider().frame(height: 12)
                HStack(spacing: 4) {
                    Circle()
                        .fill(appViewModel.signalRStatus.statusColor)
                        .frame(width: 6, height: 6)
                    Text(appViewModel.signalRStatus.displayLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AppColors.textMuted)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 6, height: 6)
                Text(healthText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(health.status == "ok" ? AppColors.textMuted : healthColor)
                    .lineLimit(1)

                if let healthRuntimeSummary {
                    Text("•")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AppColors.textMuted)
                    Text(healthRuntimeSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AppColors.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, AppLayout.contentPadding)
        .frame(height: AppLayout.statusBarHeight)
        .background(AppColors.footerBackground)
        .overlay(
            Divider().overlay(AppColors.border),
            alignment: .top
        )
    }

    // MARK: - Helpers

    private func openQueueEditor(for courtId: Int) {
        runtimeLog.log(.info, subsystem: "operator", message: "opened queue editor for court \(courtId)")
        withAnimation(.easeInOut(duration: 0.2)) {
            editorConfig = EditorConfig(id: courtId)
        }
    }

    private func closeQueueEditor(reason: String) {
        if let courtId = editorConfig?.id {
            runtimeLog.log(.info, subsystem: "operator", message: "closed queue editor for court \(courtId) via \(reason)")
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            editorConfig = nil
        }
    }

    private func openScannerModal() {
        if showSettingsModal {
            runtimeLog.log(.info, subsystem: "operator", message: "closed settings modal via switch-to-scanner")
        }
        runtimeLog.log(.info, subsystem: "operator", message: "opened scanner modal")
        withAnimation(.easeInOut(duration: 0.2)) {
            showSettingsModal = false
            showScannerModal = true
        }
    }

    private func closeScannerModal(reason: String) {
        runtimeLog.log(.info, subsystem: "operator", message: "closed scanner modal via \(reason)")
        withAnimation(.easeInOut(duration: 0.2)) {
            showScannerModal = false
        }
    }

    private func openSettingsModal() {
        if showScannerModal {
            runtimeLog.log(.info, subsystem: "operator", message: "closed scanner modal via switch-to-settings")
        }
        runtimeLog.log(.info, subsystem: "operator", message: "opened settings modal")
        withAnimation(.easeInOut(duration: 0.2)) {
            showScannerModal = false
            showSettingsModal = true
        }
    }

    private func closeSettingsModal(reason: String) {
        runtimeLog.log(.info, subsystem: "operator", message: "closed settings modal via \(reason)")
        withAnimation(.easeInOut(duration: 0.2)) {
            showSettingsModal = false
        }
    }

    private func openClearAllConfirmation() {
        runtimeLog.log(.warning, subsystem: "operator", message: "opened clear-all confirmation")
        showClearAllConfirmation = true
    }

    private func copyOverlayURL(for courtId: Int) {
        #if os(macOS)
        let url = appViewModel.overlayURL(for: courtId)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        runtimeLog.log(.info, subsystem: "operator", message: "copied overlay url for court \(courtId): \(url)")
        urlCopiedCourtId = courtId
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if urlCopiedCourtId == courtId {
                urlCopiedCourtId = nil
            }
        }
        #endif
    }
    
    private func dashboardColumnCount(for containerWidth: CGFloat) -> Int {
        let availableWidth = max(0, containerWidth - (AppLayout.contentPadding * 2))
        let preferredCardWidth: CGFloat = 460
        let rawColumnCount = Int((availableWidth + AppLayout.cardSpacing) / (preferredCardWidth + AppLayout.cardSpacing))
        return max(1, min(3, rawColumnCount))
    }
    
    private func dashboardColumns(columnCount: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: AppLayout.cardSpacing),
            count: max(1, columnCount)
        )
    }
    
    private func dashboardCardHeight(containerHeight: CGFloat, columnCount: Int, itemCount: Int) -> CGFloat {
        let safeItems = max(1, itemCount)
        let safeColumns = max(1, columnCount)
        let rows = max(1, Int(ceil(Double(safeItems) / Double(safeColumns))))
        
        let verticalInsets = AppLayout.cardSpacing * 2
        let totalSpacing = CGFloat(max(0, rows - 1)) * AppLayout.cardSpacing
        let usableHeight = max(0, containerHeight - verticalInsets - totalSpacing)
        let fitted = usableHeight / CGFloat(rows)
        
        return min(max(fitted, 220), 360)
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppViewModel())
        .frame(width: 1200, height: 800)
}
