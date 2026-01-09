import SwiftUI
#if os(macOS)
import AppKit
#endif

// Updated UI with grid layout - Build timestamp: 2025-09-01 02:15 - FORCED REBUILD

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    
    // Sheet/alert state
    @State private var editingCourtId: Int?
    @State private var renamingCourtId: Int?
    @State private var newCourtName: String = ""
    @State private var showVBLScanSheet = false
    @State private var showAssignToolSheet = false
    @State private var scanURLs = ScanURLs()
    
    // Fixed layout for exactly 10 overlay cards
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Top Control Bar with Overall Function Buttons
                TopControlBar(vm: vm, showVBLScanSheet: $showVBLScanSheet, showAssignToolSheet: $showAssignToolSheet)
                
                // Main Overlay Cards Grid
                OverlayCardsGrid(
                    vm: vm, 
                    columns: columns,
                    editingCourtId: $editingCourtId,
                    renamingCourtId: $renamingCourtId, 
                    newCourtName: $newCourtName,
                    getCourtDisplayName: getCourtDisplayName,
                    createDefaultCourt: createDefaultCourt,
                    copyOBSLink: copyOBSLink
                )
            }
            // Sheets and Alerts
            .sheet(isPresented: Binding(
                get: { editingCourtId != nil },
                set: { if !$0 { editingCourtId = nil } }
            )) {
                if let courtId = editingCourtId {
                    ImprovedQueueEditorView(initialCourtId: courtId)
                        .environmentObject(vm)
                }
            }
            .alert("Rename Overlay", isPresented: Binding(
                get: { renamingCourtId != nil },
                set: { if !$0 { renamingCourtId = nil } }
            )) {
                TextField("New name", text: $newCourtName)
                Button("Cancel", role: .cancel) { renamingCourtId = nil }
                Button("Save") {
                    if let id = renamingCourtId {
                        vm.renameCourt(id, to: newCourtName)
                    }
                    renamingCourtId = nil
                }
            } message: {
                Text("Enter a new name for this overlay (e.g., Court 1, Main Court, Side Court).")
            }
            .sheet(isPresented: $showVBLScanSheet) {
                VBLScanView(scanURLs: $scanURLs, vblBridge: vm.vblBridge)
                .environmentObject(vm)
            }
            .sheet(isPresented: $showAssignToolSheet) {
                AssignToolView(vblBridge: vm.vblBridge, vm: vm) {
                    showAssignToolSheet = false
                }
                .frame(minWidth: 800, minHeight: 600)
            }
        }
        .onAppear {
            ensureAllCourtsExist()
        }
    }
    
    private func getCourtDisplayName(_ courtId: Int) -> String {
        if courtId == 1 {
            return "Core 1"
        } else {
            return "Mevo \(courtId - 1)"
        }
    }
    
    private func createDefaultCourt(id: Int) -> Court {
        return Court(
            id: id,
            name: "Overlay \(id)",
            queue: [],
            activeIndex: nil,
            status: .idle,
            lastSnapshot: nil,
            liveSince: nil
        )
    }
    
    private func ensureAllCourtsExist() {
        // Ensure we have exactly 10 courts
        for i in 1...10 {
            if !vm.courts.contains(where: { $0.id == i }) {
                vm.addCourt(withId: i)
                vm.renameCourt(i, to: "Overlay \(i)")
            }
        }
    }
    
    private func copyOBSLink(for courtId: Int) {
        #if os(macOS)
        let url = vm.overlayURL(for: courtId)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        print("📋 Copied OBS link for Overlay \(courtId): \(url)")
        #endif
    }
}

// MARK: - OverlayCard View
struct OverlayCard: View {
    let court: Court
    let onRun: () -> Void
    let onStop: () -> Void
    let onSkipNext: () -> Void
    let onSkipPrevious: () -> Void
    let onEditQueue: () -> Void
    let onRename: () -> Void
    let onCopyOBSLink: () -> Void
    
    // Status-based background colors
    private var statusBackgroundColor: Color {
        switch court.status {
        case .idle:
            return Color.gray.opacity(0.3) // Dark gray when idle/no matches
        case .waiting:
            return Color.yellow.opacity(0.3) // Yellow when pending first match
        case .live:
            return Color.green.opacity(0.3) // Green when actively scoring
        case .finished:
            return Color.blue.opacity(0.3) // Blue when match finished, waiting for next
        case .error:
            return Color.red.opacity(0.3) // Red for errors
        }
    }
    
    // Status-based border colors
    private var statusBorderColor: Color {
        switch court.status {
        case .idle: return .gray
        case .waiting: return .yellow
        case .live: return .green
        case .finished: return .blue
        case .error: return .red
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Court Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(court.name)
                        .font(.headline.bold())
                        .foregroundColor(.primary)
                    
                    Text("Queue: \(court.queue.count) matches")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Status indicator with color coding
                VStack(alignment: .trailing, spacing: 2) {
                    Circle()
                        .fill(statusBorderColor)
                        .frame(width: 12, height: 12)
                    
                    Text(court.status.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundColor(statusBorderColor)
                }
            }
            
            // Current Match Display
            if let activeIndex = court.activeIndex,
               activeIndex < court.queue.count {
                let currentMatch = court.queue[activeIndex]
                
                VStack(alignment: .leading, spacing: 6) {
                    // Match title/label
                    Text("LIVE MATCH")
                        .font(.caption.bold())
                        .foregroundColor(.primary)
                    
                    // Team names and scores
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentMatch.team1Name ?? "Team 1")
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                            
                            Text(currentMatch.team2Name ?? "Team 2")
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        // Live scores (placeholder - would come from actual match data)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(court.lastSnapshot?.team1Score ?? 0)")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            
                            Text("\(court.lastSnapshot?.team2Score ?? 0)")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                        }
                    }
                    
                    // Previous set scores
                    if let setHistory = court.lastSnapshot?.setHistory, !setHistory.isEmpty {
                        HStack {
                            Text("Sets:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            ForEach(setHistory, id: \.setNumber) { set in
                                Text("\(set.team1Score)-\(set.team2Score)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            
                            Spacer()
                        }
                    }
                    
                    // Current set info
                    if let snapshot = court.lastSnapshot {
                        Text("Set \(snapshot.setNumber) • \(snapshot.status)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)
            }
            
            // Queue Preview - Next matches
            if court.queue.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("UP NEXT")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    
                    let nextMatches = Array(court.queue.dropFirst(max(0, (court.activeIndex ?? -1) + 1)).prefix(3))
                    
                    ForEach(Array(nextMatches.enumerated()), id: \.element.id) { index, match in
                        HStack {
                            Text("\(index + 1).")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 20, alignment: .leading)
                            
                            Text("\(match.team1Name ?? "TBD") vs \(match.team2Name ?? "TBD")")
                                .font(.caption2)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            Spacer()
                        }
                    }
                    
                    if nextMatches.isEmpty && court.queue.isEmpty {
                        Text("No matches queued")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
            }
            
            // Control buttons
            VStack(spacing: 8) {
                // Navigation controls
                HStack(spacing: 12) {
                    Button(action: onSkipPrevious) {
                        HStack(spacing: 4) {
                            Image(systemName: "backward.fill")
                            Text("Prev")
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onRun) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Start")
                        }
                        .font(.caption.bold())
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onStop) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                        }
                        .font(.caption.bold())
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onSkipNext) {
                        HStack(spacing: 4) {
                            Image(systemName: "forward.fill")
                            Text("Next")
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                
                // Action buttons row
                HStack(spacing: 8) {
                    Button(action: onEditQueue) {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.clipboard")
                            Text("Edit Queue")
                        }
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onRename) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Rename")
                        }
                        .font(.caption.bold())
                        .foregroundColor(.purple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(statusBackgroundColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusBorderColor, lineWidth: 2)
        )
    }
}

// MARK: - Overlay Cards Grid
struct OverlayCardsGrid: View {
    let vm: AppViewModel
    let columns: [GridItem]
    @Binding var editingCourtId: Int?
    @Binding var renamingCourtId: Int? 
    @Binding var newCourtName: String
    let getCourtDisplayName: (Int) -> String
    let createDefaultCourt: (Int) -> Court
    let copyOBSLink: (Int) -> Void
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: 20) {
                ForEach(0..<10, id: \.self) { index in
                    let courtId = index + 1
                    let baseCourt = vm.courts.first { $0.id == courtId } ?? createDefaultCourt(courtId)
                    let court = Court(
                        id: baseCourt.id,
                        name: getCourtDisplayName(courtId),
                        queue: baseCourt.queue,
                        activeIndex: baseCourt.activeIndex,
                        status: baseCourt.status,
                        lastSnapshot: baseCourt.lastSnapshot,
                        liveSince: baseCourt.liveSince
                    )
                    
                    OverlayCard(
                        court: court,
                        onRun: { vm.run(courtId) },
                        onStop: { vm.stop(courtId) },
                        onSkipNext: { vm.skip(courtId) },
                        onSkipPrevious: { vm.skipToPrevious(courtId) },
                        onEditQueue: { editingCourtId = courtId },
                        onRename: {
                            renamingCourtId = courtId
                            newCourtName = baseCourt.name
                        },
                        onCopyOBSLink: { copyOBSLink(courtId) }
                    )
                    .accessibilityIdentifier("overlay_card_\(courtId)")
                }
            }
            .padding()
        }
    }
}

// MARK: - Top Control Bar
struct TopControlBar: View {
    let vm: AppViewModel
    @Binding var showVBLScanSheet: Bool
    @Binding var showAssignToolSheet: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: { 
                // Start all courts
                print("Start all courts")
                for i in 1...10 {
                    vm.run(i)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                    Text("Start All")
                }
                .font(.headline.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.green)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("start_all_button")
            
            Button(action: vm.stopAll) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle.fill")
                    Text("Stop All")
                }
                .font(.headline.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stop_all_button")
            
            Button(action: vm.clearAllQueues) {
                HStack(spacing: 6) {
                    Image(systemName: "trash.circle.fill")
                    Text("Clear All")
                }
                .font(.headline.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clear_all_queues_button")
            
            Button(action: {
                showVBLScanSheet = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle.fill")
                    Text("Scan VBL")
                }
                .font(.headline.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.blue)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scan_vbl_button")
            
            Button(action: {
                showAssignToolSheet = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line.compact")
                    Text("Assign Tool")
                }
                .font(.headline.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.purple)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("assign_tool_button")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
}

// MARK: - Scan URLs Data Structure
struct ScanURLs {
    var brackets: [String] = [""]
    var pools: [String] = ["", ""]
    
    var allURLs: [String] {
        return (brackets + pools).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: - Multi-URL Input Section
struct MultiURLInputSection: View {
    @Binding var scanURLs: ScanURLs
    @ObservedObject var vblBridge: VBLPythonBridge
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Bracket URLs Section
            BracketURLsSection(scanURLs: $scanURLs)
            
            Divider()
            
            // Pool URLs Section
            PoolURLsSection(scanURLs: $scanURLs)
            
            // Scan Status and Button
            ScanButtonSection(scanURLs: $scanURLs, vblBridge: vblBridge)
        }
    }
}

struct BracketURLsSection: View {
    @Binding var scanURLs: ScanURLs
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bracket URLs:")
                    .font(.headline)
                
                Spacer()
                
                Text("Up to 4 brackets")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ForEach(0..<4, id: \.self) { index in
                BracketURLRow(scanURLs: $scanURLs, index: index)
            }
        }
    }
}

struct BracketURLRow: View {
    @Binding var scanURLs: ScanURLs
    let index: Int
    
    var body: some View {
        HStack {
            TextField("Enter bracket URL \(index + 1)...", 
                     text: Binding(
                        get: { 
                            index < scanURLs.brackets.count ? scanURLs.brackets[index] : ""
                        },
                        set: { newValue in
                            while scanURLs.brackets.count <= index {
                                scanURLs.brackets.append("")
                            }
                            scanURLs.brackets[index] = newValue
                        }
                     ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            
            if index >= scanURLs.brackets.count || scanURLs.brackets[index].isEmpty {
                Text("Optional")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60)
            } else {
                Button(action: {
                    if index < scanURLs.brackets.count {
                        scanURLs.brackets[index] = ""
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct PoolURLsSection: View {
    @Binding var scanURLs: ScanURLs
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pool URLs:")
                    .font(.headline)
                
                Spacer()
                
                Text("Up to 2 pools")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ForEach(0..<2, id: \.self) { index in
                PoolURLRow(scanURLs: $scanURLs, index: index)
            }
        }
    }
}

struct PoolURLRow: View {
    @Binding var scanURLs: ScanURLs
    let index: Int
    
    var body: some View {
        HStack {
            TextField("Enter pool URL \(index + 1)...", 
                     text: Binding(
                        get: { 
                            index < scanURLs.pools.count ? scanURLs.pools[index] : ""
                        },
                        set: { newValue in
                            while scanURLs.pools.count <= index {
                                scanURLs.pools.append("")
                            }
                            scanURLs.pools[index] = newValue
                        }
                     ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            
            if index >= scanURLs.pools.count || scanURLs.pools[index].isEmpty {
                Text("Optional")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60)
            } else {
                Button(action: {
                    if index < scanURLs.pools.count {
                        scanURLs.pools[index] = ""
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ScanButtonSection: View {
    @Binding var scanURLs: ScanURLs
    @ObservedObject var vblBridge: VBLPythonBridge
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("URLs to scan: \(scanURLs.allURLs.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            
            if !vblBridge.isScanning {
                Button(action: {
                    let urlsToScan = scanURLs.allURLs
                    if !urlsToScan.isEmpty {
                        vblBridge.scanMultipleURLs(urls: urlsToScan)
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass.circle.fill")
                        Text("Scan \(scanURLs.allURLs.count) URL\(scanURLs.allURLs.count == 1 ? "" : "s")")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(scanURLs.allURLs.isEmpty ? Color.gray : Color.blue)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(scanURLs.allURLs.isEmpty)
            } else {
                // Cancel button when scanning
                Button(action: {
                    vblBridge.cancelScan()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Cancel Scan")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - VBL Scan View
struct VBLScanView: View {
    @Binding var scanURLs: ScanURLs
    @ObservedObject var vblBridge: VBLPythonBridge
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            // Header with title and close button
            HStack {
                Text("Scan VolleyballLife Bracket")
                    .font(.title2.bold())
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.top)
            
            // Multi-URL Input Section
            MultiURLInputSection(scanURLs: $scanURLs, vblBridge: vblBridge)
                .padding(.horizontal)
            
            // Progress Section with Enhanced Live Logging
            if vblBridge.isScanning {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    
                    Text(vblBridge.scanProgress)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    // Enhanced real-time debug log display
                    if !vblBridge.scanLogs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Live Debug Log:")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("\(vblBridge.scanLogs.count) entries")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 1) {
                                    ForEach(vblBridge.scanLogs.suffix(25)) { logEntry in
                                        HStack(alignment: .top, spacing: 4) {
                                            Text(logEntry.type.icon)
                                                .font(.caption2)
                                            Text(logEntry.timeDisplay)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .frame(width: 50, alignment: .leading)
                                            Text(logEntry.message)
                                                .font(.caption)
                                                .foregroundColor(logEntry.type.color)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                        }
                                        .id(logEntry.id)
                                    }
                                }
                            }
                            .frame(height: 200)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            
            // Error Display
            if let error = vblBridge.errorMessage {
                Text("Error: \(error)")
                    .font(.body)
                    .foregroundColor(.red)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
            }
            
            // Results Section
            if !vblBridge.lastScanResults.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Found \(vblBridge.lastScanResults.count) matches:")
                        .font(.headline)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(vblBridge.lastScanResults.prefix(8).enumerated()), id: \.element.id) { index, match in
                                HStack {
                                    Text("\(index + 1).")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .frame(width: 30, alignment: .leading)
                                    
                                    Text(match.displayName)
                                        .font(.body)
                                    
                                    Spacer()
                                    
                                    if match.apiURL != nil {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            
                            if vblBridge.lastScanResults.count > 8 {
                                Text("... and \(vblBridge.lastScanResults.count - 8) more")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8)
                            }
                        }
                    }
                    .frame(maxHeight: 250)
                    
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            // Only clear logs and UI state when window opens, preserve lastScanResults
            vblBridge.scanLogs.removeAll()
            vblBridge.scanProgress = ""
            vblBridge.errorMessage = nil
            print("🔍 VBL Scan window opened - cleared UI state only")
        }
    }
}

struct CourtAssignmentSheet: View {
    let matches: [VBLPythonBridge.VBLMatchData]
    let vm: AppViewModel
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var matchAssignments: [UUID: Int] = [:] // Match ID -> Overlay Number
    @State private var groupedByCourt: [String: [VBLPythonBridge.VBLMatchData]] = [:]
    @State private var courtAssignments: [String: Int] = [:] // Court Name -> Overlay Number
    
    var body: some View {
        VStack(spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assign Matches to Court Overlays")
                        .font(.title.bold())
                    
                    Text("Found \(matches.count) matches from VolleyballLife bracket. Assign them to your court overlays (1-10).")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(groupedByCourt.keys.sorted()), id: \.self) { courtName in
                            if let courtMatches = groupedByCourt[courtName] {
                                CourtAssignmentGroupView(
                                    courtName: courtName, 
                                    matches: courtMatches,
                                    courtAssignment: Binding(
                                        get: { courtAssignments[courtName] ?? 0 },
                                        set: { newValue in 
                                            courtAssignments[courtName] = newValue
                                            // Update individual match assignments
                                            for match in courtMatches {
                                                matchAssignments[match.id] = newValue
                                            }
                                        }
                                    ),
                                    matchAssignments: $matchAssignments
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(minHeight: 400)
                
                // Action buttons
                HStack(spacing: 16) {
                    Button("Back to Scan") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Spacer()
                    
                    Button(action: autoAssignCourts) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.rays")
                            Text("Auto Assign")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.blue)
                    
                    Button(action: assignMatchesToOverlays) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Import to Courts")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                    .disabled(matchAssignments.values.contains(0))
                }
                .padding(.horizontal)
                .padding(.vertical, 20)
        }
        .padding(20)
        .onAppear {
            print("🎯 CourtAssignmentSheet appeared with \(matches.count) matches")
            for (index, match) in matches.enumerated() {
                print("  Received Match \(index + 1): \(match.displayName) - Court: \(match.courtDisplay)")
            }
            groupMatchesByCourt()
        }
    }
    
    private func groupMatchesByCourt() {
        var groups: [String: [VBLPythonBridge.VBLMatchData]] = [:]
        
        for match in matches {
            let court = match.courtDisplay
            if groups[court] == nil {
                groups[court] = []
            }
            groups[court]?.append(match)
        }
        
        // Force UI update by using DispatchQueue
        DispatchQueue.main.async {
            self.groupedByCourt = groups
            
            // Initialize assignments
            for match in self.matches {
                self.matchAssignments[match.id] = 0 // 0 means unassigned
            }
        }
    }
    
    private func autoAssignCourts() {
        var newCourtAssignments: [String: Int] = [:]
        var newMatchAssignments: [UUID: Int] = [:]
        
        // Simple logic: Court 1 → Overlay 1, Court 2 → Overlay 2, etc.
        let sortedCourts = groupedByCourt.keys.sorted()
        
        for (index, courtName) in sortedCourts.enumerated() {
            // Try to extract court number first, fallback to sequential assignment
            let courtNumber = extractCourtNumber(from: courtName)
            let assignedOverlay = min(courtNumber ?? (index + 1), 10)
            
            newCourtAssignments[courtName] = assignedOverlay
            
            if let courtMatches = groupedByCourt[courtName] {
                for match in courtMatches {
                    newMatchAssignments[match.id] = assignedOverlay
                }
            }
            
            print("🎯 Auto-assigned Court '\(courtName)' → Overlay \(assignedOverlay)")
        }
        
        courtAssignments = newCourtAssignments
        matchAssignments = newMatchAssignments
        
        print("✅ Auto-assignment completed for \(sortedCourts.count) courts")
    }
    
    private func assignMatchesToOverlays() {
        // Group matches by assigned overlay
        var matchesByOverlay: [Int: [VBLPythonBridge.VBLMatchData]] = [:]
        
        for match in matches {
            if let overlayNumber = matchAssignments[match.id], overlayNumber > 0 {
                if matchesByOverlay[overlayNumber] == nil {
                    matchesByOverlay[overlayNumber] = []
                }
                matchesByOverlay[overlayNumber]?.append(match)
            }
        }
        
        // Populate the overlays
        for (overlayNumber, overlayMatches) in matchesByOverlay {
            vm.populateCourtFromVBL(courtId: overlayNumber, matches: overlayMatches)
        }
        
        onComplete()
        dismiss()
    }
    
    private func extractCourtNumber(from courtName: String) -> Int? {
        let digits = courtName.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
}

struct CourtAssignmentGroupView: View {
    let courtName: String
    let matches: [VBLPythonBridge.VBLMatchData]
    @Binding var courtAssignment: Int
    @Binding var matchAssignments: [UUID: Int]
    
    // Helper computed properties to simplify complex expressions
    private func isMatchAssigned(_ matchId: UUID) -> Bool {
        return matchAssignments[matchId] != nil && matchAssignments[matchId]! > 0
    }
    
    private func assignmentColor(_ matchId: UUID) -> Color {
        return isMatchAssigned(matchId) ? .primary : .secondary
    }
    
    private func backgroundColorForMatch(_ matchId: UUID) -> Color {
        return isMatchAssigned(matchId) ? Color.green.opacity(0.1) : Color.gray.opacity(0.05)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Court header with mass assignment
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Court: \(courtName)")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    Text("\(matches.count) match\(matches.count == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Mass assign dropdown for this court
                Menu {
                    ForEach(1...10, id: \.self) { overlayNumber in
                        Button("Overlay \(overlayNumber)") {
                            courtAssignment = overlayNumber
                        }
                    }
                } label: {
                    HStack {
                        Text("Assign All to Overlay \(courtAssignment > 0 ? String(courtAssignment) : "?")")
                            .foregroundColor(courtAssignment > 0 ? .primary : .secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            
            // Individual match assignments
            VStack(alignment: .leading, spacing: 8) {
                ForEach(matches, id: \.id) { match in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.displayName)
                                .font(.body)
                                .fontWeight(.medium)
                            
                            if let time = match.startTime {
                                Text("⏰ \(time)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Menu {
                            ForEach(1...10, id: \.self) { overlayNumber in
                                Button("Overlay \(overlayNumber)") {
                                    matchAssignments[match.id] = overlayNumber
                                }
                            }
                        } label: {
                            HStack {
                                Text("Overlay \(matchAssignments[match.id] ?? 0)")
                                    .foregroundColor(assignmentColor(match.id))
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(backgroundColorForMatch(match.id))
                    .cornerRadius(8)
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}