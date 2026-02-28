//
//  ConfigStore.swift
//  MultiCourtScore v2
//
//  Configuration persistence for app settings
//

import Foundation

class ConfigStore {
    private let fileManager = FileManager.default
    
    // MARK: - App Support Directory
    
    private var appSupportURL: URL {
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
    
    // MARK: - Credentials (Secure)
    
    struct VBLCredentials: Codable {
        var username: String
        var password: String
    }
    
    func loadCredentials() -> VBLCredentials? {
        guard exists(at: credentialsURL),
              let creds = try? load(VBLCredentials.self, from: credentialsURL) else {
            return nil
        }
        return creds
    }
    
    func saveCredentials(_ credentials: VBLCredentials) {
        try? save(credentials, to: credentialsURL)
    }
    
    func clearCredentials() {
        try? fileManager.removeItem(at: credentialsURL)
    }
}
