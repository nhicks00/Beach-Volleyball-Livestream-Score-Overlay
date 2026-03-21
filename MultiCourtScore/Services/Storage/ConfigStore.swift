//
//  ConfigStore.swift
//  MultiCourtScore v2
//
//  Configuration persistence for app settings
//

import Foundation
import Security

class ConfigStore {
    private let fileManager = FileManager.default
    private let appSupportOverride: URL?

    init(appSupportOverride: URL? = nil) {
        self.appSupportOverride = appSupportOverride
    }
    
    // MARK: - App Support Directory
    
    private var appSupportURL: URL {
        if let overrideURL = appSupportOverride {
            if !fileManager.fileExists(atPath: overrideURL.path) {
                try? fileManager.createDirectory(at: overrideURL, withIntermediateDirectories: true)
            }
            return overrideURL
        }

        if let overridePath = ProcessInfo.processInfo.environment["MULTICOURTSCORE_APP_SUPPORT_DIR"],
           !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath, isDirectory: true)
            if !fileManager.fileExists(atPath: url.path) {
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }

        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MultiCourtScore")
        
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        
        return url
    }
    
    // MARK: - Config Files
    
    var courtsConfigURL: URL {
        appSupportURL.appendingPathComponent("courts_config.json")
    }
    
    var settingsURL: URL {
        appSupportURL.appendingPathComponent("settings.json")
    }
    
    var credentialsURL: URL {
        appSupportURL.appendingPathComponent("credentials.json")
    }
    
    var sessionURL: URL {
        appSupportURL.appendingPathComponent("session.json")
    }
    
    // MARK: - Generic Save/Load
    
    func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
    
    func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }
    
    func exists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
    
    // MARK: - Settings
    
    struct AppSettings: Codable {
        var serverPort: Int = NetworkConstants.webSocketPort
        var pollingInterval: TimeInterval = NetworkConstants.pollingInterval
        var autoStartPolling: Bool = false
        var showDebugInfo: Bool = false
        var overlayTheme: String = "dark"
        var defaultScoreboardLayout: String = "bottom-left"
        var showSocialBar: Bool = true
        var showNextMatchBar: Bool = true
        var broadcastTransitionsEnabled: Bool = false
        var holdScoreDuration: TimeInterval = 60     // post-match hold seconds
        var staleMatchTimeout: TimeInterval = 900    // auto-advance after N seconds of inactivity
        var signalREnabled: Bool = true

        enum CodingKeys: String, CodingKey {
            case serverPort
            case pollingInterval
            case autoStartPolling
            case showDebugInfo
            case overlayTheme
            case defaultScoreboardLayout
            case showSocialBar
            case showNextMatchBar
            case broadcastTransitionsEnabled
            case holdScoreDuration
            case staleMatchTimeout
            case signalREnabled
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort) ?? NetworkConstants.webSocketPort
            pollingInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .pollingInterval) ?? NetworkConstants.pollingInterval
            autoStartPolling = try container.decodeIfPresent(Bool.self, forKey: .autoStartPolling) ?? false
            showDebugInfo = try container.decodeIfPresent(Bool.self, forKey: .showDebugInfo) ?? false
            overlayTheme = try container.decodeIfPresent(String.self, forKey: .overlayTheme) ?? "dark"
            defaultScoreboardLayout = try container.decodeIfPresent(String.self, forKey: .defaultScoreboardLayout) ?? "bottom-left"
            showSocialBar = try container.decodeIfPresent(Bool.self, forKey: .showSocialBar) ?? true
            showNextMatchBar = try container.decodeIfPresent(Bool.self, forKey: .showNextMatchBar) ?? true
            broadcastTransitionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .broadcastTransitionsEnabled) ?? false
            holdScoreDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .holdScoreDuration) ?? 60
            staleMatchTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .staleMatchTimeout) ?? 900
            signalREnabled = try container.decodeIfPresent(Bool.self, forKey: .signalREnabled) ?? true
        }
    }
    
    func loadSettings() -> AppSettings {
        guard exists(at: settingsURL),
              let settings = try? load(AppSettings.self, from: settingsURL) else {
            return AppSettings()
        }
        return settings
    }
    
    func saveSettings(_ settings: AppSettings) {
        try? save(settings, to: settingsURL)
    }
    
    // MARK: - Credentials (Keychain)

    private static let keychainService = "com.multicourtscore.vbl-credentials"
    private static let keychainAccount = "vbl-login"

    struct VBLCredentials: Codable {
        var username: String
        var password: String
    }

    func loadCredentials() -> VBLCredentials? {
        // Try Keychain first
        if let creds = loadCredentialsFromKeychain() {
            return creds
        }
        // Fall back to legacy file and migrate
        if exists(at: credentialsURL),
           let creds = try? load(VBLCredentials.self, from: credentialsURL) {
            saveCredentialsToKeychain(creds)
            try? fileManager.removeItem(at: credentialsURL)
            return creds
        }
        return nil
    }

    func saveCredentials(_ credentials: VBLCredentials) {
        saveCredentialsToKeychain(credentials)
        // Remove legacy file if it exists
        if exists(at: credentialsURL) {
            try? fileManager.removeItem(at: credentialsURL)
        }
    }

    func clearCredentials() {
        clearCredentialsFromKeychain()
        if exists(at: credentialsURL) {
            try? fileManager.removeItem(at: credentialsURL)
        }
    }

    // MARK: - Keychain Helpers

    private func saveCredentialsToKeychain(_ creds: VBLCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadCredentialsFromKeychain() -> VBLCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(VBLCredentials.self, from: data)
    }

    private func clearCredentialsFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
