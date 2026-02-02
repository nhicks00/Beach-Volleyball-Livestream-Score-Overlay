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

struct EditorConfig: Identifiable {
    let id: Int
}

struct DashboardView: View {
    @EnvironmentObject var appViewModel: AppViewModel

    // State
    @State private var renamingCourtId: Int?
    @State private var newCourtName = ""

    // Sheet state
    @State private var showScannerSheet = false
    @State private var showSettingsSheet = false
    @State private var editorConfig: EditorConfig?

    // Filter
    @State private var courtFilter: CourtFilter = .all

    // Adaptive grid - larger cards to fill fullscreen better
    private let columns = [
        GridItem(.adaptive(minimum: 480, maximum: 700), spacing: AppLayout.cardSpacing)
    ]

    private var filteredCourts: [Court] {
        appViewModel.courts.filter { courtFilter.matches($0) }
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Toolbar header
                toolbar

                // Courts grid
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
                                onCopyURL: { copyOverlayURL(for: court.id) }
                            )
                        }
                    }
                    .padding(.horizontal, AppLayout.contentPadding)
                    .padding(.vertical, AppLayout.cardSpacing)
                }

                // Status bar footer
                statusBar
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
                
                QueueEditorView(courtId: config.id)
                    .environmentObject(appViewModel)
                    .frame(minWidth: 1100, minHeight: 700)
                    .background(AppColors.background)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.5), radius: 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: editorConfig != nil)
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
        // Modal sheets (scanner and settings still use sheets)
        .sheet(isPresented: $showScannerSheet) {
            ScanWorkflowView()
                .environmentObject(appViewModel)
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
                .environmentObject(appViewModel)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            // Left: App name + connection badge
            HStack(spacing: 12) {
                Text(AppConfig.appName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.textPrimary)

                ConnectionBadge(isConnected: true)
            }

            Spacer()

            // Center: Filter segmented control
            filterPicker

            Spacer()

            // Right: Actions
            HStack(spacing: 8) {
                Button { appViewModel.startAllPolling() } label: {
                    Label("Start All", systemImage: "play.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.success)

                Button { appViewModel.stopAllPolling() } label: {
                    Label("Stop All", systemImage: "stop.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.error)

                Divider()
                    .frame(height: 20)

                Button { showScannerSheet = true } label: {
                    Label("Scan VBL", systemImage: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.primary)

                Button(role: .destructive) {
                    appViewModel.clearAllQueues()
                } label: {
                    Label("Clear All", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)

                Button { showSettingsSheet = true } label: {
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
            let totalMatches = appViewModel.courts.reduce(0) { $0 + $1.queue.count }

            HStack(spacing: 4) {
                Circle()
                    .fill(liveCount > 0 ? AppColors.success : AppColors.textMuted)
                    .frame(width: 6, height: 6)
                Text("\(liveCount) live")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textMuted)
            }

            Text("\(totalMatches) queued")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textMuted)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(AppColors.success)
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
        print("Copied overlay URL: \(url)")
        #endif
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppViewModel())
        .frame(width: 1200, height: 800)
}
