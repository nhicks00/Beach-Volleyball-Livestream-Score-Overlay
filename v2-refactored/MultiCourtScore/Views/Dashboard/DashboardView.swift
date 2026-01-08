//
//  DashboardView.swift
//  MultiCourtScore v2
//
//  Main dashboard with court overlay grid
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    
    // Sheet states
    @State private var showScannerSheet = false
    @State private var showAssignmentSheet = false
    @State private var editingCourtId: Int?
    @State private var renamingCourtId: Int?
    @State private var newCourtName = ""
    
    // Grid layout for 5x2 court cards
    private let columns = [
        GridItem(.flexible(), spacing: AppLayout.cardSpacing),
        GridItem(.flexible(), spacing: AppLayout.cardSpacing)
    ]
    
    var body: some View {
        ZStack {
            // Background
            AppColors.background
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Control Bar
                ControlBar(
                    onStartAll: { appViewModel.startAllPolling() },
                    onStopAll: { appViewModel.stopAllPolling() },
                    onClearAll: { appViewModel.clearAllQueues() },
                    onScanVBL: { showScannerSheet = true },
                    onAssignTool: { showAssignmentSheet = true }
                )
                .padding(.horizontal, AppLayout.contentPadding)
                .padding(.top, AppLayout.sectionPadding)
                .padding(.bottom, AppLayout.cardSpacing)
                
                // Courts Grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: AppLayout.cardSpacing) {
                        ForEach(appViewModel.courts) { court in
                            CourtCard(
                                court: court,
                                onStart: { appViewModel.startPolling(for: court.id) },
                                onStop: { appViewModel.stopPolling(for: court.id) },
                                onSkipNext: { appViewModel.skipToNext(court.id) },
                                onSkipPrevious: { appViewModel.skipToPrevious(court.id) },
                                onEditQueue: { editingCourtId = court.id },
                                onRename: {
                                    renamingCourtId = court.id
                                    newCourtName = court.name
                                },
                                onCopyURL: { copyOverlayURL(for: court.id) }
                            )
                        }
                    }
                    .padding(.horizontal, AppLayout.contentPadding)
                    .padding(.bottom, AppLayout.contentPadding)
                }
            }
        }
        // Sheets
        .sheet(isPresented: $showScannerSheet) {
            ScannerView()
                .environmentObject(appViewModel)
        }
        .sheet(isPresented: $showAssignmentSheet) {
            AssignmentView()
                .environmentObject(appViewModel)
        }
        .sheet(item: $editingCourtId) { courtId in
            QueueEditorView(courtId: courtId)
                .environmentObject(appViewModel)
        }
        // Rename Alert
        .alert("Rename Overlay", isPresented: Binding(
            get: { renamingCourtId != nil },
            set: { if !$0 { renamingCourtId = nil } }
        )) {
            TextField("New name", text: $newCourtName)
            Button("Cancel", role: .cancel) { renamingCourtId = nil }
            Button("Save") {
                if let id = renamingCourtId {
                    appViewModel.renameCourt(id, to: newCourtName)
                }
                renamingCourtId = nil
            }
        } message: {
            Text("Enter a new name for this overlay")
        }
    }
    
    private func copyOverlayURL(for courtId: Int) {
        #if os(macOS)
        let url = appViewModel.overlayURL(for: courtId)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        print("📋 Copied overlay URL: \(url)")
        #endif
    }
}

// MARK: - Int Extension for Sheet Binding
extension Int: Identifiable {
    public var id: Int { self }
}

#Preview {
    DashboardView()
        .environmentObject(AppViewModel())
        .frame(width: 1200, height: 800)
}
