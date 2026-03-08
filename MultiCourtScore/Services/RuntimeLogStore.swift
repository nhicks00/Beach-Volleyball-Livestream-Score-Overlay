//
//  RuntimeLogStore.swift
//  MultiCourtScore v2
//
//  Persistent rolling runtime log for field diagnostics.
//

import Foundation

enum RuntimeLogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

enum DiagnosticsBundleError: LocalizedError {
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .archiveFailed(let message):
            return message
        }
    }
}

final class RuntimeLogStore: @unchecked Sendable {
    static let shared = RuntimeLogStore(fileURL: RuntimeLogStore.defaultFileURL())

    struct Attachment {
        let fileName: String
        let data: Data
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let fileURL: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.multicourtscore.runtime-log", qos: .utility)
    private let maxFileBytes = 512_000
    private let retainedBytes = 384_000

    init(fileURL: URL) {
        self.fileURL = fileURL
        ensureDirectoryExists()
    }

    var logFilePath: String {
        fileURL.path
    }

    var logFileURL: URL {
        fileURL
    }

    func log(_ level: RuntimeLogLevel = .info, subsystem: String, message: String) {
        let timestamp = Self.formatter.string(from: Date())
        let line = "\(timestamp) [\(level.rawValue)] [\(subsystem)] \(message)"
        print(line)

        queue.async { [fileURL] in
            self.ensureDirectoryExists()
            self.appendLine(line, to: fileURL)
            self.trimIfNeeded()
        }
    }

    func recentEntries(maxBytes: Int = 64_000) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                return ""
            }

            let suffix = data.suffix(maxBytes)
            return Self.decodeAlignedText(from: Data(suffix))
        }
    }

    func recentProblemEntries(
        maxBytes: Int = 64_000,
        maxCount: Int = 5,
        since: Date? = nil
    ) -> [String] {
        queue.sync {
            guard maxCount > 0 else { return [] }
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                return []
            }

            let suffix = data.suffix(maxBytes)
            let text = Self.decodeAlignedText(from: Data(suffix))
            let lines = text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter {
                    $0.contains("[\(RuntimeLogLevel.warning.rawValue)]") ||
                    $0.contains("[\(RuntimeLogLevel.error.rawValue)]")
                }
                .filter { line in
                    guard let since else { return true }
                    guard let timestamp = Self.timestamp(fromLogLine: line) else { return true }
                    return timestamp >= since
                }

            return Array(lines.suffix(maxCount))
        }
    }

    func clear() {
        queue.sync {
            ensureDirectoryExists()
            try? Data().write(to: fileURL, options: .atomic)
        }
    }

    func exportSnapshot(to destinationURL: URL) throws {
        try queue.sync {
            ensureDirectoryExists()
            let data = (try? Data(contentsOf: fileURL)) ?? Data()
            try data.write(to: destinationURL, options: .atomic)
        }
    }

    func exportDiagnosticsBundle<Manifest: Encodable>(
        to destinationURL: URL,
        manifest: Manifest,
        attachments: [Attachment]
    ) throws {
        let bundleName = destinationURL.deletingPathExtension().lastPathComponent
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleDirectory = stagingRoot.appendingPathComponent(bundleName, isDirectory: true)

        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        let logData = queue.sync { () -> Data in
            ensureDirectoryExists()
            return (try? Data(contentsOf: fileURL)) ?? Data()
        }

        try logData.write(to: bundleDirectory.appendingPathComponent("runtime.log"), options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleDirectory.appendingPathComponent("manifest.json"), options: .atomic)

        for attachment in attachments {
            try attachment.data.write(
                to: bundleDirectory.appendingPathComponent(attachment.fileName),
                options: .atomic
            )
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try archiveDirectory(bundleDirectory, to: destinationURL)
    }

    private func appendLine(_ line: String, to url: URL) {
        let data = Data((line + "\n").utf8)

        if fileManager.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { _ = try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func trimIfNeeded() {
        guard let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue,
              size > maxFileBytes,
              let data = try? Data(contentsOf: fileURL) else {
            return
        }

        let tail = Data(data.suffix(retainedBytes))
        let trimmedText = Self.decodeAlignedText(from: tail)
        try? Data(trimmedText.utf8).write(to: fileURL, options: .atomic)
    }

    private func ensureDirectoryExists() {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func archiveDirectory(_ sourceDirectory: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--norsrc",
            "--noextattr",
            "--noqtn",
            "--noacl",
            "--keepParent",
            sourceDirectory.path,
            destinationURL.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiagnosticsBundleError.archiveFailed(message?.isEmpty == false ? message! : "Failed to create diagnostics bundle")
        }
    }

    static func defaultExportsDirectory(appSupportOverride: URL? = nil) -> URL {
        let fileManager = FileManager.default
        let exportsURL = baseDirectory(fileManager: fileManager, appSupportOverride: appSupportOverride)
            .appendingPathComponent("Archives", isDirectory: true)
        try? fileManager.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        return exportsURL
    }

    static func defaultFileURL(appSupportOverride: URL? = nil) -> URL {
        let fileManager = FileManager.default
        let baseURL = baseDirectory(fileManager: fileManager, appSupportOverride: appSupportOverride)
        let logsURL = baseURL.appendingPathComponent("Logs", isDirectory: true)
        try? fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
        migrateLegacyLogIfNeeded(baseURL: baseURL, logsURL: logsURL, fileManager: fileManager)
        return logsURL.appendingPathComponent("runtime.log")
    }

    private static func baseDirectory(
        fileManager: FileManager = .default,
        appSupportOverride: URL? = nil
    ) -> URL {
        let baseURL: URL

        if let appSupportOverride {
            baseURL = appSupportOverride
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            baseURL = fileManager.temporaryDirectory
                .appendingPathComponent("MultiCourtScoreTests-Logs", isDirectory: true)
        } else if let overridePath = ProcessInfo.processInfo.environment["MULTICOURTSCORE_APP_SUPPORT_DIR"],
                  !overridePath.isEmpty {
            baseURL = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MultiCourtScore", isDirectory: true)
        }

        try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }

    private static func migrateLegacyLogIfNeeded(
        baseURL: URL,
        logsURL: URL,
        fileManager: FileManager
    ) {
        let legacyURL = baseURL.appendingPathComponent("runtime.log")
        let currentURL = logsURL.appendingPathComponent("runtime.log")

        guard legacyURL.path != currentURL.path,
              fileManager.fileExists(atPath: legacyURL.path),
              !fileManager.fileExists(atPath: currentURL.path) else {
            return
        }

        try? fileManager.moveItem(at: legacyURL, to: currentURL)
    }

    private static func decodeAlignedText(from data: Data) -> String {
        guard !data.isEmpty else { return "" }

        let alignedData: Data
        if let newlineIndex = data.firstIndex(of: 0x0A), newlineIndex < data.index(before: data.endIndex) {
            alignedData = Data(data.suffix(from: data.index(after: newlineIndex)))
        } else {
            alignedData = data
        }

        return String(data: alignedData, encoding: .utf8) ?? String(decoding: alignedData, as: UTF8.self)
    }

    private static func timestamp(fromLogLine line: String) -> Date? {
        guard let firstSeparator = line.firstIndex(of: " ") else {
            return nil
        }

        let timestamp = String(line[..<firstSeparator])
        return formatter.date(from: timestamp)
    }
}
