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

final class RuntimeLogStore: @unchecked Sendable {
    static let shared = RuntimeLogStore(fileURL: RuntimeLogStore.defaultFileURL())

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

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let baseURL: URL

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
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
        return baseURL.appendingPathComponent("runtime.log")
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
}
