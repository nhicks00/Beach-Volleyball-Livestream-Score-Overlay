//
//  MultiCourtScoreApp.swift
//  MultiCourtScore v2
//
//  Refactored for improved maintainability and performance
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RunningAppDescriptor: Equatable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let isTerminated: Bool
}

enum SingleInstanceGuard {
    static func shouldBypassDuplicateLaunchGuard(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if arguments.contains("--uitest-mode") {
            return true
        }

        // XCTest launches the app host with these environment keys set.
        return environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCInjectBundleInto"] != nil
    }

    static func duplicateProcessID(
        bundleIdentifier: String?,
        currentProcessID: pid_t,
        runningApplications: [RunningAppDescriptor]
    ) -> pid_t? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }

        return runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier &&
            $0.processIdentifier != currentProcessID &&
            !$0.isTerminated
        }?.processIdentifier
    }
}

@main
struct MultiCourtScoreApp: App {
    @StateObject private var appViewModel: AppViewModel
    @State private var didBootstrap = false

    init() {
        let viewModel = AppViewModel()
        _appViewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(appViewModel)
                .background(WindowBehaviorConfigurator())
                .onAppear {
                    guard !didBootstrap else { return }
                    didBootstrap = true
                    guard !handleDuplicateLaunchIfNeeded() else { return }
                    applyTheme(appViewModel.appSettings.overlayTheme)
                    Task { @MainActor in
                        let didStart = await appViewModel.ensureServicesRunning()
                        if didStart && appViewModel.appSettings.autoStartPolling {
                            appViewModel.startAllPolling()
                        }
                    }
                }
                .onChange(of: appViewModel.appSettings.overlayTheme) { _, newTheme in
                    applyTheme(newTheme)
                }
                .frame(minWidth: 900, minHeight: 720)
        }
        .defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--uitest-mode") ? .presented : .automatic)
        .restorationBehavior(ProcessInfo.processInfo.arguments.contains("--uitest-mode") ? .disabled : .automatic)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .windowSize) {
                Button("Toggle Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
            CommandMenu("Courts") {
                Button("Start All Polling") {
                    appViewModel.startAllPolling()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Stop All Polling") {
                    appViewModel.stopAllPolling()
                }
                .keyboardShortcut(".", modifiers: [.command])

                Divider()

                Button("Clear All Queues") {
                    appViewModel.clearAllQueues()
                }
            }
            CommandMenu("Support") {
                Button("Copy Support Summary") {
                    copySupportSummary()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Export Diagnostics Bundle...") {
                    exportDiagnosticsBundle()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
            }
        }
    }

    private func applyTheme(_ theme: String) {
        NSApp.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
    }

    private func handleDuplicateLaunchIfNeeded() -> Bool {
        guard !SingleInstanceGuard.shouldBypassDuplicateLaunchGuard(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return false
        }

        let runningApplications = NSWorkspace.shared.runningApplications
        let descriptors = runningApplications.map {
            RunningAppDescriptor(
                bundleIdentifier: $0.bundleIdentifier,
                processIdentifier: $0.processIdentifier,
                isTerminated: $0.isTerminated
            )
        }
        let duplicateProcessID = SingleInstanceGuard.duplicateProcessID(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            currentProcessID: ProcessInfo.processInfo.processIdentifier,
            runningApplications: descriptors
        )
        let duplicateRunningApp = runningApplications.first {
            $0.processIdentifier == duplicateProcessID
        }

        guard let duplicateRunningApp else {
            return false
        }

        RuntimeLogStore.shared.log(
            .warning,
            subsystem: "app-lifecycle",
            message: "duplicate launch detected; activating existing process \(duplicateRunningApp.processIdentifier) and terminating new instance"
        )
        duplicateRunningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.async {
            NSApp.hide(nil)
            NSApp.terminate(nil)
        }
        return true
    }

    private func exportDiagnosticsBundle() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = RuntimeLogStore.defaultExportsDirectory()
        panel.nameFieldStringValue = appViewModel.suggestedDiagnosticsBundleFilename()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .data]

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try appViewModel.exportDiagnosticsBundle(to: destinationURL)
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Diagnostics export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func copySupportSummary() {
        let summary = appViewModel.supportSummaryText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        RuntimeLogStore.shared.log(.info, subsystem: "operator", message: "copied support summary")
    }
}

private struct WindowBehaviorConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }
    
    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.formUnion([.fullScreenPrimary, .fullScreenAllowsTiling])
        window.tabbingMode = .disallowed

        if ProcessInfo.processInfo.arguments.contains("--uitest-mode") {
            let targetSize = NSSize(width: 1440, height: 940)
            if window.frame.size != targetSize {
                window.setContentSize(targetSize)
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Force the green zoom button to use native fullscreen instead of desktop zoom.
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.target = window
            zoomButton.action = #selector(NSWindow.toggleFullScreen(_:))
        }
    }
}
