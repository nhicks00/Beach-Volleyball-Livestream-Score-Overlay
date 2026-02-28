//
//  SettingsView.swift
//  MultiCourtScore v2
//
//  App settings with sidebar navigation and dark theme
//

import SwiftUI

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
    let onClose: (() -> Void)?

    @State private var selectedTab: SettingsTab = .general
    @State private var settings = ConfigStore().loadSettings()
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var showingCredentialsSaved = false
    @State private var showSettingsSaved = false
    @State private var searchText = ""

    private let configStore = ConfigStore()

    init(onClose: (() -> Void)? = nil) {
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
                    Button(action: closeSettings) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppColors.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(AppColors.surfaceHover))
                    }
                    .buttonStyle(.plain)
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
        .onExitCommand { closeSettings() }
        .onAppear {
            loadCredentials()
        }
    }

    private func closeSettings() {
        if let onClose {
            onClose()
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
                                    Slider(value: $settings.pollingInterval, in: 1...10, step: 0.5)
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
                    VStack(spacing: 12) {
                        Toggle("Auto-start polling on launch", isOn: $settings.autoStartPolling)
                            .toggleStyle(.switch)
                        Toggle("Show debug information", isOn: $settings.showDebugInfo)
                            .toggleStyle(.switch)
                    }
                }

                // Theme
                DetailSection(title: "Theme") {
                    Picker("Theme", selection: $settings.overlayTheme) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("Transparent").tag("transparent")
                    }
                    .pickerStyle(.segmented)
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

                Text("Credentials are stored in your app's support directory and are never committed to code.")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textMuted)

                HStack(spacing: 16) {
                    Button("Clear") {
                        clearCredentials()
                    }
                    .buttonStyle(.bordered)

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
        VStack(spacing: 0) {
            // Log viewer
            ScrollViewReader { proxy in
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
                                Text("No log entries yet")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color(hex: "#1A1A1A"))
                .cornerRadius(8)
                .padding(16)
            }

            // Log toolbar
            HStack {
                Text("\(appViewModel.scannerViewModel.scanLogs.count) entries")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(AppColors.textMuted)

                Spacer()

                Button("Clear Logs") {
                    appViewModel.scannerViewModel.scanLogs.removeAll()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
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

            Text("2025 Nathan Hicks")
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

    private func saveCredentials() {
        let creds = ConfigStore.VBLCredentials(username: username, password: password)
        configStore.saveCredentials(creds)
        showingCredentialsSaved = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingCredentialsSaved = false
        }
    }

    private func clearCredentials() {
        configStore.clearCredentials()
        username = ""
        password = ""
    }

    private func loadCredentials() {
        if let creds = configStore.loadCredentials() {
            username = creds.username
            password = creds.password
        }
    }
}

// MARK: - Notifications Pane Content (merged from NotificationSettingsView)

struct NotificationsPaneContent: View {
    @StateObject private var notificationService = NotificationService.shared
    @State private var showTestAlert = false
    @State private var testAlertMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Enable toggle
                DetailSection(title: "General") {
                    Toggle("Enable Notifications", isOn: $notificationService.isEnabled)
                        .toggleStyle(.switch)
                }

                // Webhook
                DetailSection(title: "Webhook Configuration") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Webhook URL")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textMuted)

                        TextField("https://hooks.zapier.com/...", text: $notificationService.webhookURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        Text("Use IFTTT, Zapier, or Make to receive notifications via email, SMS, or other channels.")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textMuted)

                        Button {
                            Task {
                                await notificationService.sendTestNotification()
                                testAlertMessage = "Test notification sent!"
                                showTestAlert = true
                            }
                        } label: {
                            Label("Send Test", systemImage: "paperplane.fill")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .disabled(notificationService.webhookURL.isEmpty || !notificationService.isEnabled)
                    }
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
        .alert("Test Notification", isPresented: $showTestAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(testAlertMessage)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppViewModel())
}
