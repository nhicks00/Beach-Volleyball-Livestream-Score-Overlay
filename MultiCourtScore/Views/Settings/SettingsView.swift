//
//  SettingsView.swift
//  MultiCourtScore v2
//
//  App settings with sidebar navigation and dark theme
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings Navigation

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case credentials = "Credentials"
    case notifications = "Notifications"
    case logs = "Logs"
    case about = "About"

    var icon: String {
        switch self {
        case .general: return "gear"
        case .credentials: return "key"
        case .notifications: return "bell"
        case .logs: return "terminal"
        case .about: return "info.circle"
        }
    }

    var isDividerBefore: Bool {
        self == .logs
    }
}

struct SettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let onClose: ((String) -> Void)?

    @State private var selectedTab: SettingsTab = .general
    @State private var settings = ConfigStore().loadSettings()
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var showClearCredsConfirmation = false
    @State private var showingCredentialsSaved = false
    @State private var showSettingsSaved = false
    @State private var searchText = ""
    @State private var credentialsLoadRequested = false
    @State private var runtimeLogPreview = ""
    @State private var runtimeLogStatusMessage: String?
    @State private var runtimeLogStatusIsError = false

    private let configStore = ConfigStore()
    private let runtimeLog = RuntimeLogStore.shared

    init(onClose: ((String) -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            settingsSidebar

            // Content
            VStack(spacing: 0) {
                // Tab header
                HStack {
                    Text(selectedTab.rawValue)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                    Spacer()
                    Button {
                        closeSettings(reason: "close-button")
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppColors.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(AppColors.surfaceHover))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.close")
                    .help("Close (Esc)")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(AppColors.surface)
                .overlay(
                    Divider().overlay(AppColors.border),
                    alignment: .bottom
                )

                // Tab content
                tabContent
            }
        }
        .frame(minWidth: 650, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background(AppColors.background)
        .onExitCommand { closeSettings(reason: "escape") }
        .background(
            EscapeKeyMonitor {
                closeSettings(reason: "escape")
            }
        )
        .onAppear {
            loadCredentialsIfNeeded()
            refreshRuntimeDiagnostics()
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .logs {
                refreshRuntimeDiagnostics()
            }
        }
    }

    private func closeSettings(reason: String) {
        if let onClose {
            onClose(reason)
        } else {
            dismiss()
        }
    }

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.textMuted)
                    .font(.system(size: 11))
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppColors.surfaceElevated)
            )
            .padding(12)

            // Items
            VStack(alignment: .leading, spacing: 2) {
                ForEach(filteredTabs, id: \.self) { tab in
                    if tab.isDividerBefore {
                        Divider()
                            .overlay(AppColors.border)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                    }

                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13))
                                .foregroundColor(selectedTab == tab ? AppColors.primary : AppColors.textMuted)
                                .frame(width: 20)

                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundColor(selectedTab == tab ? AppColors.textPrimary : AppColors.textSecondary)

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedTab == tab ? AppColors.surfaceHover : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: 180)
        .background(AppColors.sidebarBackground)
        .overlay(
            Divider().overlay(AppColors.border),
            alignment: .trailing
        )
    }

    private var filteredTabs: [SettingsTab] {
        if searchText.isEmpty {
            return SettingsTab.allCases
        }
        return SettingsTab.allCases.filter {
            $0.rawValue.lowercased().contains(searchText.lowercased())
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            generalPane
        case .credentials:
            credentialsPane
        case .notifications:
            notificationsPane
        case .logs:
            logsPane
        case .about:
            aboutPane
        }
    }

    // MARK: - General Pane

    private var generalPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Server
                DetailSection(title: "Server") {
                    VStack(spacing: 12) {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Port")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textMuted)
                                HStack(spacing: 8) {
                                    TextField("Port", text: Binding(
                                        get: { String(settings.serverPort) },
                                        set: { if let val = Int($0) { settings.serverPort = val } }
                                    ))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)

                                    Circle()
                                        .fill(AppColors.success)
                                        .frame(width: 8, height: 8)
                                    Text("Available")
                                        .font(.system(size: 11))
                                        .foregroundColor(AppColors.success)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Polling Interval")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textMuted)

                                HStack(spacing: 8) {
                                    Slider(value: $settings.pollingInterval, in: 0.5...10, step: 0.5)
                                        .frame(width: 150)
                                    Text("\(settings.pollingInterval, specifier: "%.1f")s")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(AppColors.textSecondary)
                                        .frame(width: 36)
                                }
                            }
                        }
                    }
                }

                // Behavior
                DetailSection(title: "Behavior") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Auto-start polling on launch", isOn: $settings.autoStartPolling)
                            .toggleStyle(.switch)
                        Toggle("Show social media bar on overlay", isOn: $settings.showSocialBar)
                            .toggleStyle(.switch)
                            .onChange(of: settings.showSocialBar) { _, newValue in
                                appViewModel.appSettings.showSocialBar = newValue
                            }
                    }
                }

                // Timers
                DetailSection(title: "Timers") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Stepper(
                                "Post-match hold: \(Int(settings.holdScoreDuration))s (\(Int(settings.holdScoreDuration / 60))m)",
                                value: $settings.holdScoreDuration,
                                in: 30...600,
                                step: 30
                            )
                            .onChange(of: settings.holdScoreDuration) { _, newValue in
                                appViewModel.appSettings.holdScoreDuration = newValue
                            }
                            Text("How long to display final scores before advancing to next match.")
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textMuted)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Stepper(
                                "Stale match timeout: \(Int(settings.staleMatchTimeout))s (\(Int(settings.staleMatchTimeout / 60))m)",
                                value: $settings.staleMatchTimeout,
                                in: 300...3600,
                                step: 60
                            )
                            .onChange(of: settings.staleMatchTimeout) { _, newValue in
                                appViewModel.appSettings.staleMatchTimeout = newValue
                            }
                            Text("Auto-advance if no score changes for this duration.")
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textMuted)
                        }
                    }
                }

                // Live Push (SignalR)
                DetailSection(title: "Live Push (SignalR)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable SignalR push updates", isOn: Binding(
                            get: { settings.signalREnabled },
                            set: { newValue in
                                settings.signalREnabled = newValue
                                appViewModel.setSignalREnabled(newValue)
                            }
                        ))
                        .toggleStyle(.switch)

                        Text("Receives live score mutations via SignalR. Requires VBL credentials. Polling continues as fallback.")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textMuted)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(appViewModel.signalRStatus.statusColor)
                                .frame(width: 7, height: 7)
                            Text(appViewModel.signalRStatus.displayLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .opacity(settings.signalREnabled ? 1 : 0.4)
                    }
                }

                // Theme
                DetailSection(title: "Theme") {
                    Picker("Theme", selection: $settings.overlayTheme) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.overlayTheme) { _, newTheme in
                        appViewModel.appSettings.overlayTheme = newTheme
                    }
                }

                // Default Scoreboard Layout
                DetailSection(title: "Default Scoreboard Layout") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Layout", selection: $settings.defaultScoreboardLayout) {
                            Text("Center").tag("center")
                            Text("Top-Left").tag("top-left")
                            Text("Bottom-Left").tag("bottom-left")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: settings.defaultScoreboardLayout) { _, newLayout in
                            appViewModel.appSettings.defaultScoreboardLayout = newLayout
                        }

                        Text("Applied to all overlays unless overridden per-court.")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textMuted)
                    }
                }

                HStack {
                    Spacer()

                    if showSettingsSaved {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(AppColors.success)
                            Text("Settings saved!")
                                .foregroundColor(AppColors.success)
                        }
                        .font(.system(size: 13))
                        .transition(.opacity)
                    }

                    Button("Save Settings") {
                        saveSettings()
                        withAnimation {
                            showSettingsSaved = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation {
                                showSettingsSaved = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.success)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Credentials Pane

    private var credentialsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailSection(title: "VolleyballLife Login") {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(AppColors.textMuted)
                                .frame(width: 20)
                            TextField("Email", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.emailAddress)
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .foregroundColor(AppColors.textMuted)
                                .frame(width: 20)

                            if showPassword {
                                TextField("Password", text: $password)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("Password", text: $password)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundColor(AppColors.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Credentials are stored securely in your macOS Keychain.")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textMuted)

                HStack(spacing: 16) {
                    Button("Clear") {
                        showClearCredsConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .alert("Clear Credentials?", isPresented: $showClearCredsConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button("Clear", role: .destructive) { clearCredentials() }
                    } message: {
                        Text("This will remove your saved VBL login credentials. You will need to re-enter them to scan.")
                    }

                    Button("Save Credentials") {
                        saveCredentials()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.success)
                    .disabled(username.isEmpty || password.isEmpty)
                }

                if showingCredentialsSaved {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(AppColors.success)
                        Text("Credentials saved!")
                            .foregroundColor(AppColors.success)
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(24)
        }
    }

    // MARK: - Notifications Pane (merged from NotificationSettingsView)

    private var notificationsPane: some View {
        NotificationsPaneContent()
    }

    // MARK: - Logs Pane (NEW)

    private var logsPane: some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                systemHealthSection(health: currentHealthSnapshot)

                DetailSection(title: "Runtime Diagnostics") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Log File")
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textMuted)
                            Text(runtimeLog.logFilePath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(AppColors.textSecondary)
                                .textSelection(.enabled)
                        }

                        HStack(spacing: 8) {
                            Button("Refresh") {
                                refreshRuntimeDiagnostics()
                            }
                            .accessibilityIdentifier("settings.logs.refreshRuntime")

                            Button("Reveal in Finder") {
                                revealRuntimeLogInFinder()
                            }
                            .accessibilityIdentifier("settings.logs.revealRuntime")

                            Button("Copy Path") {
                                copyRuntimeLogPath()
                            }
                            .accessibilityIdentifier("settings.logs.copyRuntimePath")

                            Button("Export Runtime Log...") {
                                exportRuntimeLog()
                            }
                            .accessibilityIdentifier("settings.logs.exportRuntime")

                            Button("Export Diagnostics Bundle...") {
                                exportDiagnosticsBundle()
                            }
                            .accessibilityIdentifier("settings.logs.exportDiagnostics")
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))

                        if let runtimeLogStatusMessage {
                            Text(runtimeLogStatusMessage)
                                .font(.system(size: 11))
                                .foregroundColor(runtimeLogStatusIsError ? AppColors.error : AppColors.success)
                        }

                        ScrollView {
                            Group {
                                if runtimeLogPreview.isEmpty {
                                    Text("No runtime diagnostics entries yet")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(AppColors.textMuted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                } else {
                                    Text(runtimeLogPreview)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(AppColors.textSecondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                }
                            }
                        }
                        .frame(minHeight: 180, maxHeight: 240)
                        .background(Color(hex: "#1A1A1A"))
                        .cornerRadius(8)
                    }
                }

                DetailSection(title: "Scanner Logs") {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(appViewModel.scannerViewModel.scanLogs) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.timeDisplay)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(AppColors.textMuted)
                                            .frame(width: 60, alignment: .leading)

                                        Text(entry.type.icon)
                                            .font(.system(size: 11))

                                        Text(entry.message)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(entry.type.color)
                                            .lineLimit(nil)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 3)
                                    .id(entry.id)
                                }

                                if appViewModel.scannerViewModel.scanLogs.isEmpty {
                                    VStack(spacing: 8) {
                                        Image(systemName: "terminal")
                                            .font(.system(size: 32))
                                            .foregroundColor(AppColors.textMuted)
                                        Text("No scanner log entries yet")
                                            .font(.system(size: 13))
                                            .foregroundColor(AppColors.textMuted)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 40)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(minHeight: 180, maxHeight: 260)
                        .background(Color(hex: "#1A1A1A"))
                        .cornerRadius(8)

                        HStack {
                            Text("\(appViewModel.scannerViewModel.scanLogs.count) entries")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(AppColors.textMuted)

                            Spacer()

                            Button("Clear Scanner Logs") {
                                appViewModel.scannerViewModel.scanLogs.removeAll()
                                runtimeLog.log(.warning, subsystem: "operator", message: "cleared scanner logs from settings")
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 11))
                            .accessibilityIdentifier("settings.logs.clearScanner")
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func systemHealthSection(health: OverlayHealthSnapshot) -> some View {
        DetailSection(title: "System Health") {
            VStack(alignment: .leading, spacing: 10) {
                healthRow(
                    label: "Overall",
                    value: health.status.uppercased(),
                    color: health.status == "ok" ? AppColors.success : AppColors.warning
                )
                healthRow(
                    label: "Overlay Server",
                    value: health.serverStatus == "running" ? "Running on localhost:\(health.port)" : "Stopped",
                    color: health.serverStatus == "running" ? AppColors.success : AppColors.error
                )
                healthRow(
                    label: "SignalR",
                    value: health.signalREnabled ? health.signalRStatus : "Disabled",
                    color: health.signalREnabled ? appViewModel.signalRStatus.statusColor : AppColors.textMuted
                )
                healthRow(
                    label: "Polling Watch",
                    value: health.stalePollingCourtIds.isEmpty
                        ? "No stale courts"
                        : "Stale courts: \(health.stalePollingCourtIds.map(String.init).joined(separator: ", "))",
                    color: health.stalePollingCourtIds.isEmpty ? AppColors.success : AppColors.warning
                )
                healthRow(
                    label: "Court Coverage",
                    value: "\(health.courtCount) courts in snapshot",
                    color: AppColors.textSecondary
                )

                if let startupError = health.startupError, !startupError.isEmpty {
                    Text(startupError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AppColors.error)
                        .textSelection(.enabled)
                }

                Text("Diagnostics bundles include this snapshot as health.json.")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textMuted)
            }
        }
    }

    // MARK: - About Pane

    private var aboutPane: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "volleyball.fill")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(
                    colors: [AppColors.primary, AppColors.info],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Text(AppConfig.appName)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppColors.textPrimary)

            Text("Version \(AppConfig.version)")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)

            Text("Beach volleyball live streaming score overlay system.\nScrapes VolleyballLife brackets and feeds live scores to OBS.")
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textMuted)
                .padding(.horizontal, 32)

            Spacer()

            Text("© 2026 Nathan Hicks")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textMuted)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func saveSettings() {
        configStore.saveSettings(settings)
        appViewModel.appSettings = settings
    }

    private var currentHealthSnapshot: OverlayHealthSnapshot {
        WebSocketHub.shared.currentHealthSnapshot(port: appViewModel.appSettings.serverPort)
    }

    private func healthRow(label: String, value: String, color: Color) -> some View {
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(AppColors.textMuted)
                .frame(width: 96, alignment: .leading)

            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(color)
                .textSelection(.enabled)
        }
    }

    private func saveCredentials() {
        let creds = ConfigStore.VBLCredentials(username: username, password: password)
        configStore.saveCredentials(creds)
        showingCredentialsSaved = true
        appViewModel.reconnectSignalRIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingCredentialsSaved = false
        }
    }

    private func clearCredentials() {
        configStore.clearCredentials()
        username = ""
        password = ""
    }

    private func loadCredentialsIfNeeded() {
        guard !credentialsLoadRequested else { return }
        credentialsLoadRequested = true

        let store = configStore
        DispatchQueue.global(qos: .userInitiated).async {
            let creds = store.loadCredentials()
            DispatchQueue.main.async {
                guard let creds else { return }
                username = creds.username
                password = creds.password
            }
        }
    }

    private func refreshRuntimeDiagnostics() {
        runtimeLogPreview = runtimeLog.recentEntries(maxBytes: 24_000)
    }

    private func revealRuntimeLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([runtimeLog.logFileURL])
        runtimeLog.log(.info, subsystem: "operator", message: "revealed runtime log in Finder")
        runtimeLogStatusMessage = "Revealed runtime log in Finder"
        runtimeLogStatusIsError = false
    }

    private func copyRuntimeLogPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(runtimeLog.logFilePath, forType: .string)
        runtimeLog.log(.info, subsystem: "operator", message: "copied runtime log path")
        runtimeLogStatusMessage = "Copied runtime log path"
        runtimeLogStatusIsError = false
    }

    private func exportRuntimeLog() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = suggestedRuntimeLogFilename()
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try runtimeLog.exportSnapshot(to: destinationURL)
            runtimeLog.log(.info, subsystem: "operator", message: "exported runtime log to \(destinationURL.lastPathComponent)")
            runtimeLogStatusMessage = "Exported runtime log to \(destinationURL.lastPathComponent)"
            runtimeLogStatusIsError = false
        } catch {
            runtimeLog.log(.warning, subsystem: "operator", message: "runtime log export failed: \(error.localizedDescription)")
            runtimeLogStatusMessage = "Export failed: \(error.localizedDescription)"
            runtimeLogStatusIsError = true
        }
    }

    private func exportDiagnosticsBundle() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = appViewModel.suggestedDiagnosticsBundleFilename()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .data]

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try appViewModel.exportDiagnosticsBundle(to: destinationURL, runtimeLog: runtimeLog)
            runtimeLogStatusMessage = "Exported diagnostics bundle to \(destinationURL.lastPathComponent)"
            runtimeLogStatusIsError = false
        } catch {
            runtimeLogStatusMessage = "Diagnostics export failed: \(error.localizedDescription)"
            runtimeLogStatusIsError = true
        }
    }

    private func suggestedRuntimeLogFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "MultiCourtScore-runtime-\(formatter.string(from: Date())).log"
    }

}

private struct EscapeKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                    self.onEscape()
                    return nil
                }
                return event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

// MARK: - Notifications Pane Content (merged from NotificationSettingsView)

struct NotificationsPaneContent: View {
    @StateObject private var notificationService = NotificationService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Enable toggle
                DetailSection(title: "General") {
                    Toggle("Enable Notifications", isOn: $notificationService.isEnabled)
                        .toggleStyle(.switch)
                }

                // Event checkboxes
                DetailSection(title: "Events") {
                    VStack(spacing: 8) {
                        Toggle("Court Changes", isOn: $notificationService.notifyOnCourtChange)
                            .toggleStyle(.switch)
                        Toggle("Match Completions", isOn: $notificationService.notifyOnMatchComplete)
                            .toggleStyle(.switch)
                    }
                }
            }
            .padding(24)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppViewModel())
}
