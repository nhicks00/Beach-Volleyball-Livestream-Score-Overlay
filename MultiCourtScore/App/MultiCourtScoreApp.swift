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
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
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
