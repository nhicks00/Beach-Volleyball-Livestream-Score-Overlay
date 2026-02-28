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

enum DashboardTab: String, CaseIterable {
    case courts = "Courts"
    case changes = "Change Log"
}

struct EditorConfig: Identifiable {
    let id: Int
}

struct DashboardView: View {
    @EnvironmentObject var appViewModel: AppViewModel

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

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()
            
            GeometryReader { rootGeo in
                VStack(spacing: 0) {
                    // Toolbar header
                    toolbar(for: rootGeo.size.width)

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
                                            onStart: { appViewModel.startPolling(for: court.id) },
                                            onStop: { appViewModel.stopPolling(for: court.id) },
                                            onSkipNext: { appViewModel.skipToNext(court.id) },
                                            onSkipPrevious: { appViewModel.skipToPrevious(court.id) },
                                            onEditQueue: { editorConfig = EditorConfig(id: court.id) },
                                            onRename: {
                                                renamingCourtId = court.id
                                                newCourtName = court.name
                                            },
                                            onCopyURL: { copyOverlayURL(for: court.id) },
                                            isCopied: urlCopiedCourtId == court.id
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
            
            // Queue Editor Overlay - click outside to dismiss
            if let config = editorConfig {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            editorConfig = nil
                        }
                    }
                
                GeometryReader { geo in
                    QueueEditorView(courtId: config.id, onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editorConfig = nil
                            }
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showScannerModal = false
                        }
                    }

                GeometryReader { geo in
                    ScanWorkflowView(onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showScannerModal = false
                        }
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSettingsModal = false
                        }
                    }

                GeometryReader { geo in
                    SettingsView(onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSettingsModal = false
                        }
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
            // Left: App name + connection badge
            HStack(spacing: 12) {
                Text(AppConfig.appName)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                ConnectionBadge(isConnected: WebSocketHub.shared.isRunning)
            }

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
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.success)

                Button { appViewModel.stopAllPolling() } label: {
                    Label("Stop All", systemImage: "stop.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.error)

                Divider()
                    .frame(height: 20)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettingsModal = false
                        showScannerModal = true
                    }
                } label: {
                    Label("Scan VBL", systemImage: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.primary)

                Button(role: .destructive) {
                    showClearAllConfirmation = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showScannerModal = false
                        showSettingsModal = true
                    }
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(.horizontal, AppLayout.contentPadding)
        .padding(.vertical, 10)
        .background(AppColors.toolbarBackground)
        .overlay(
            Divider().overlay(AppColors.border),
            alignment: .bottom
        )
    }
    
    private var compactToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(AppConfig.appName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    
                    ConnectionBadge(isConnected: WebSocketHub.shared.isRunning)
                }

                Spacer(minLength: 8)
                
                HStack(spacing: 6) {
                    Button { appViewModel.startAllPolling() } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.success)
                    .help("Start All")
                    
                    Button { appViewModel.stopAllPolling() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.error)
                    .help("Stop All")
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSettingsModal = false
                            showScannerModal = true
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.primary)
                    .help("Scan VBL")
                    
                    Button(role: .destructive) {
                        showClearAllConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .help("Clear All")
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showScannerModal = false
                            showSettingsModal = true
                        }
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.bordered)
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
        .padding(.vertical, 10)
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
                let count = appViewModel.courts.filter { filter.matches($0) }.count
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

    private var statusBar: some View {
        HStack(spacing: 16) {
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

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(WebSocketHub.shared.isRunning ? AppColors.success : AppColors.error)
                    .frame(width: 6, height: 6)
                Text("localhost:\(String(appViewModel.appSettings.serverPort))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(AppColors.textMuted)
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

    private func copyOverlayURL(for courtId: Int) {
        #if os(macOS)
        let url = appViewModel.overlayURL(for: courtId)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
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
