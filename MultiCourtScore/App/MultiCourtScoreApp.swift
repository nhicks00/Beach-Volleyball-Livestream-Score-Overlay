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

struct WindowVisibilityDescriptor: Equatable {
    let isVisible: Bool
    let isMiniaturized: Bool
}

enum DashboardWindowRecovery {
    static func shouldReopenDashboard(hasVisibleWindows: Bool) -> Bool {
        !hasVisibleWindows
    }

    static func shouldReopenDashboard(windows: [WindowVisibilityDescriptor]) -> Bool {
        !windows.contains { $0.isVisible && !$0.isMiniaturized }
    }
}

final class DashboardAppDelegate: NSObject, NSApplicationDelegate {
    var reopenDashboard: (() -> Void)?

    private func requestDashboardReopen() {
        let reopenDashboard = self.reopenDashboard
        DispatchQueue.main.async {
            reopenDashboard?()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard DashboardWindowRecovery.shouldReopenDashboard(hasVisibleWindows: flag) else {
            return false
        }

        RuntimeLogStore.shared.log(
            .warning,
            subsystem: "app-lifecycle",
            message: "reopening dashboard after app reopen with no visible windows"
        )
        requestDashboardReopen()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let windowDescriptors = NSApp.windows.map {
            WindowVisibilityDescriptor(
                isVisible: $0.isVisible,
                isMiniaturized: $0.isMiniaturized
            )
        }

        guard DashboardWindowRecovery.shouldReopenDashboard(windows: windowDescriptors) else {
            return
        }

        RuntimeLogStore.shared.log(
            .warning,
            subsystem: "app-lifecycle",
            message: "restoring dashboard because app became active with no visible windows"
        )
        requestDashboardReopen()
    }
}

@main
struct MultiCourtScoreApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(DashboardAppDelegate.self) private var appDelegate
    @StateObject private var appViewModel: AppViewModel
    @State private var didBootstrap = false

    init() {
        let viewModel = AppViewModel()
        _appViewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        Window("Dashboard", id: "dashboard") {
            DashboardView()
                .environmentObject(appViewModel)
                .background(WindowBehaviorConfigurator())
                .onAppear {
                    appDelegate.reopenDashboard = { openDashboardWindow() }
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
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Show Dashboard") {
                    openDashboardWindow()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
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

                Button("Export Diagnostics + Copy Summary...") {
                    exportDiagnosticsBundleAndCopySummary()
                }
            }
        }
    }

    private func applyTheme(_ theme: String) {
        NSApp.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
    }

    private func openDashboardWindow() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
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

    private func exportDiagnosticsBundleAndCopySummary() {
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
            copySupportSummary()
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Diagnostics export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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
