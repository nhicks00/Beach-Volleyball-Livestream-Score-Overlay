//
//  MultiCourtScoreApp.swift
//  MultiCourtScore v2
//
//  Refactored for improved maintainability and performance
//

import SwiftUI

@main
struct MultiCourtScoreApp: App {
    @StateObject private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(appViewModel)
                .background(WindowBehaviorConfigurator())
                .onAppear {
                    appViewModel.startServices()
                    applyTheme(appViewModel.appSettings.overlayTheme)
                    if appViewModel.appSettings.autoStartPolling {
                        appViewModel.startAllPolling()
                    }
                }
                .onChange(of: appViewModel.appSettings.overlayTheme) { _, newTheme in
                    applyTheme(newTheme)
                }
                .frame(minWidth: 920, minHeight: 640)
        }
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
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }
    }

    private func applyTheme(_ theme: String) {
        NSApp.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
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

        // Force the green zoom button to use native fullscreen instead of desktop zoom.
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.target = window
            zoomButton.action = #selector(NSWindow.toggleFullScreen(_:))
        }
    }
}
