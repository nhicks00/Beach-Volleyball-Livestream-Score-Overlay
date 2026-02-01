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
                    // Force dark mode appearance
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    // Auto-start polling if configured
                    if appViewModel.appSettings.autoStartPolling {
                        appViewModel.startAllPolling()
                    }
                }
                .preferredColorScheme(.dark)
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

        WindowGroup(id: "scanner") {
            ScanWorkflowView()
                .environmentObject(appViewModel)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 750)

        WindowGroup(id: "queue-editor", for: Int.self) { $courtId in
            if let courtId {
                QueueEditorView(courtId: courtId)
                    .environmentObject(appViewModel)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 650)

        Settings {
            SettingsView()
                .environmentObject(appViewModel)
        }
    }
}
