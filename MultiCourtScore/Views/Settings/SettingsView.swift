//
//  SettingsView.swift
//  MultiCourtScore v2
//
//  App settings and preferences
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    
    @State private var settings = ConfigStore().loadSettings()
    @State private var username = ""
    @State private var password = ""
    @State private var showingCredentialsSaved = false
    
    private let configStore = ConfigStore()
    
    var body: some View {
        TabView {
            // General Settings
            GeneralSettingsTab(settings: $settings, onSave: saveSettings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            // VBL Credentials
            CredentialsTab(
                username: $username,
                password: $password,
                showingSuccess: $showingCredentialsSaved,
                onSave: saveCredentials,
                onClear: clearCredentials
            )
            .tabItem {
                Label("Credentials", systemImage: "key")
            }
            
            // Notifications
            NotificationSettingsView()
                .tabItem {
                    Label("Notifications", systemImage: "bell")
                }
            
            // About
            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadCredentials()
        }
    }
    
    // MARK: - Actions
    
    private func saveSettings() {
        configStore.saveSettings(settings)
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

// MARK: - General Settings Tab
struct GeneralSettingsTab: View {
    @Binding var settings: ConfigStore.AppSettings
    let onSave: () -> Void
    
    var body: some View {
        Form {
            Section("Server") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $settings.serverPort, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("Polling Interval")
                    Spacer()
                    TextField("Seconds", value: $settings.pollingInterval, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    Text("seconds")
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Behavior") {
                Toggle("Auto-start polling on launch", isOn: $settings.autoStartPolling)
                Toggle("Show debug information", isOn: $settings.showDebugInfo)
            }
            
            Section("Overlay") {
                Picker("Theme", selection: $settings.overlayTheme) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("Transparent").tag("transparent")
                }
            }
            
            Section {
                HStack {
                    Spacer()
                    Button("Save Settings") {
                        onSave()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Credentials Tab
struct CredentialsTab: View {
    @Binding var username: String
    @Binding var password: String
    @Binding var showingSuccess: Bool
    let onSave: () -> Void
    let onClear: () -> Void
    
    var body: some View {
        Form {
            Section("VolleyballLife Login") {
                TextField("Email", text: $username)
                    .textContentType(.emailAddress)
                
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            
            Section {
                Text("Credentials are stored securely in your app's support directory and are never committed to code.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section {
                HStack(spacing: 16) {
                    Spacer()
                    
                    Button("Clear") {
                        onClear()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Save Credentials") {
                        onSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty)
                    
                    Spacer()
                }
                
                if showingSuccess {
                    HStack {
                        Spacer()
                        Label("Credentials saved!", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About Tab
struct AboutTab: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "volleyball.fill")
                .font(.system(size: 64))
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            
            Text(AppConfig.appName)
                .font(.title.bold())
            
            Text("Version \(AppConfig.version)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("Beach volleyball live streaming score overlay system.\nScrapes VolleyballLife brackets and feeds live scores to OBS.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)
            
            Spacer()
            
            Text("© 2025 Nathan Hicks")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppViewModel())
}
