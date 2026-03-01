//
//  ScanWorkflowView.swift
//  MultiCourtScore v2
//
//  Unified VBL scanning and assignment workflow with sidebar navigation
//

import SwiftUI

// MARK: - Workflow Steps

enum ScanWorkflowStep: Int, CaseIterable {
    case scanSources = 0
    case selectLiveCourts = 1
    case configureOutput = 2
    case queueManagement = 3

    var title: String {
        switch self {
        case .scanSources: return "Scan Sources"
        case .selectLiveCourts: return "Select Live Courts"
        case .configureOutput: return "Configure Output"
        case .queueManagement: return "Queue Management"
        }
    }

    var icon: String {
        switch self {
        case .scanSources: return "link.badge.plus"
        case .selectLiveCourts: return "video.badge.checkmark"
        case .configureOutput: return "video.badge.waveform"
        case .queueManagement: return "rectangle.3.group"
        }
    }
}

// MARK: - Main View

struct ScanWorkflowView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let onClose: (() -> Void)?

    @State private var currentStep: ScanWorkflowStep = .scanSources
    @State private var matchAssignments: [UUID: Int] = [:]
    @State private var courtAssignments: [String: Int] = [:]
    @State private var selectedCourts: Set<String> = []
    @State private var courtSearchText = ""

    private var viewModel: ScannerViewModel { appViewModel.scannerViewModel }
    private var scanResults: [ScannerViewModel.VBLMatch] { viewModel.scanResults }
    private var groupedByCourt: [String: [ScannerViewModel.VBLMatch]] { viewModel.groupedByCourt }

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar navigation
            sidebar

            // Main content
            VStack(spacing: 0) {
                stepHeader
                stepContent
                stepFooter
            }
        }
        .frame(
            minWidth: 960,
            idealWidth: 1380,
            maxWidth: .infinity,
            minHeight: 680,
            idealHeight: 980,
            maxHeight: .infinity
        )
        .background(AppColors.background)
        .onExitCommand { closeWorkflow() }
        .onAppear {
            if !viewModel.scanResults.isEmpty {
                currentStep = .selectLiveCourts
                selectedCourts = Set(groupedByCourt.keys)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            HStack {
                Text("Scan & Assign")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Button { closeWorkflow() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppColors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider().overlay(AppColors.border)

            // Steps
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ScanWorkflowStep.allCases, id: \.rawValue) { step in
                    sidebarItem(step: step)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: AppLayout.sidebarWidth)
        .background(AppColors.sidebarBackground)
        .overlay(
            Divider().overlay(AppColors.border),
            alignment: .trailing
        )
    }

    private func sidebarItem(step: ScanWorkflowStep) -> some View {
        let isActive = step == currentStep
        let isComplete = step.rawValue < currentStep.rawValue
        let isEnabled = canNavigateTo(step)

        return Button {
            if isEnabled {
                currentStep = step
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.success)
                    } else {
                        Image(systemName: step.icon)
                            .font(.system(size: 14))
                            .foregroundColor(isActive ? AppColors.primary : AppColors.textMuted)
                    }
                }
                .frame(width: 24)

                Text(step.title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? AppColors.textPrimary : (isEnabled ? AppColors.textSecondary : AppColors.textMuted))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? AppColors.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func canNavigateTo(_ step: ScanWorkflowStep) -> Bool {
        switch step {
        case .scanSources: return true
        case .selectLiveCourts: return !scanResults.isEmpty
        case .configureOutput: return !scanResults.isEmpty
        case .queueManagement: return !scanResults.isEmpty
        }
    }

    // MARK: - Step Header

    private var stepHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentStep.title)
                    .font(AppTypography.title)
                    .foregroundColor(AppColors.textPrimary)

                Text(stepSubtitle)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }
            Spacer()

            Button { closeWorkflow() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(AppColors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AppColors.surfaceHover))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(AppLayout.contentPadding)
        .background(AppColors.surface)
        .overlay(
            Divider().overlay(AppColors.border),
            alignment: .bottom
        )
    }

    private var stepSubtitle: String {
        switch currentStep {
        case .scanSources: return "Enter bracket and pool URLs to scan"
        case .selectLiveCourts: return "\(selectedCourts.count) of \(groupedByCourt.keys.count) courts with cameras"
        case .configureOutput: return "Map courts to camera slots"
        case .queueManagement: return "Drag matches between camera columns"
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .scanSources:
            URLEntryStep(
                viewModel: viewModel,
                onScanComplete: {
                    selectedCourts = Set(groupedByCourt.keys)
                    currentStep = .selectLiveCourts
                }
            )
        case .selectLiveCourts:
            SelectCourtsStep(
                groupedByCourt: groupedByCourt,
                selectedCourts: $selectedCourts,
                searchText: $courtSearchText
            )
        case .configureOutput:
            CourtMappingStep(
                groupedByCourt: groupedByCourt.filter { selectedCourts.contains($0.key) },
                courtAssignments: $courtAssignments
            )
        case .queueManagement:
            KanbanQueueStep(
                scanResults: scanResults,
                liveCourts: selectedCourts,
                assignments: $matchAssignments,
                onImport: importAndClose
            )
        }
    }

    // MARK: - Step Footer

    private var stepFooter: some View {
        HStack {
            if currentStep.rawValue > 0 {
                Button {
                    if let prev = ScanWorkflowStep(rawValue: currentStep.rawValue - 1) {
                        currentStep = prev
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(AppTypography.callout)
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep == .queueManagement {
                Button(action: importAndClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import as Queue")
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.success)
                .disabled(matchAssignments.values.filter { $0 > 0 }.isEmpty)
            } else if currentStep != .scanSources {
                Button {
                    if let next = ScanWorkflowStep(rawValue: currentStep.rawValue + 1) {
                        if currentStep == .selectLiveCourts {
                            // Going to configure output
                            let allCourts = Array(groupedByCourt.keys.filter { selectedCourts.contains($0) })
                            CourtMappingStore.shared.updateUnmappedCourts(from: allCourts)
                        }
                        if currentStep == .configureOutput {
                            persistCourtMappings()
                            initializeAssignments()
                        }
                        currentStep = next
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.primary)
            }
        }
        .padding(.horizontal, AppLayout.contentPadding)
        .padding(.vertical, 12)
        .background(AppColors.surface)
        .overlay(
            Divider().overlay(AppColors.border),
            alignment: .top
        )
    }

    // MARK: - Assignment Logic

    private func initializeAssignments() {
        for match in scanResults {
            guard selectedCourts.contains(match.courtDisplay) else {
                matchAssignments[match.id] = 0
                continue
            }
            
            // Matches on courts without mapped cameras default to Standby (0).
            matchAssignments[match.id] = courtAssignments[match.courtDisplay] ?? 0
        }
    }
    
    private func persistCourtMappings() {
        let mappingStore = CourtMappingStore.shared
        let selectedCourtNames = Array(groupedByCourt.keys.filter { selectedCourts.contains($0) })
        
        for courtName in selectedCourtNames {
            let mappedCamera = courtAssignments[courtName] ?? 0
            if mappedCamera > 0 {
                mappingStore.setMapping(courtNames: [courtName], to: mappedCamera)
            } else {
                mappingStore.removeCourtName(courtName)
            }
        }
        
        mappingStore.updateUnmappedCourts(from: selectedCourtNames)
    }

    private func closeWorkflow() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func importAndClose() {
        var matchesByOverlay: [Int: [ScannerViewModel.VBLMatch]] = [:]

        let assignedCount = scanResults.filter { matchAssignments[$0.id] ?? 0 > 0 }.count
        print("[Import] Total scan results: \(scanResults.count), assigned to overlays: \(assignedCount)")

        for match in scanResults {
            guard let overlayId = matchAssignments[match.id], overlayId > 0 else { continue }
            if matchesByOverlay[overlayId] == nil {
                matchesByOverlay[overlayId] = []
            }
            matchesByOverlay[overlayId]?.append(match)
        }

        for (overlayId, matches) in matchesByOverlay {
            let sortedMatches = matches.sorted { a, b in
                let aIsPool = a.matchType?.lowercased().contains("pool") ?? false
                let bIsPool = b.matchType?.lowercased().contains("pool") ?? false
                if aIsPool && !bIsPool { return true }
                if !aIsPool && bIsPool { return false }
                return a.index < b.index
            }

            let droppedCount = sortedMatches.filter { $0.apiURL == nil || $0.apiURL?.isEmpty == true }.count
            let matchItems = viewModel.createMatchItems(from: sortedMatches)
            print("[Import] Overlay \(overlayId): \(sortedMatches.count) matches → \(matchItems.count) items queued, \(droppedCount) dropped (no apiURL)")
            appViewModel.replaceQueue(overlayId, with: matchItems, startIndex: 0)
        }

        closeWorkflow()
    }
}

// MARK: - Step 1: URL Entry (reuses existing structure, dark-styled)

struct URLEntryStep: View {
    @ObservedObject var viewModel: ScannerViewModel
    let onScanComplete: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: AppLayout.sectionSpacing) {
                HStack(alignment: .top, spacing: AppLayout.cardSpacing) {
                    // Bracket URLs card
                    URLInputCard(
                        title: "Bracket URLs",
                        subtitle: "\(viewModel.bracketURLs.filter { !$0.isEmpty }.count) entered",
                        urls: $viewModel.bracketURLs,
                        placeholder: "https://volleyballlife.com/.../brackets",
                        onAddURL: { viewModel.bracketURLs.append("") }
                    )

                    // Pool URLs card
                    URLInputCard(
                        title: "Pool URLs",
                        subtitle: "\(viewModel.poolURLs.filter { !$0.isEmpty }.count) entered",
                        urls: $viewModel.poolURLs,
                        placeholder: "https://volleyballlife.com/.../pools",
                        onAddURL: { viewModel.poolURLs.append("") }
                    )
                }

                // Scan action
                ScanActionCard(viewModel: viewModel, onScanComplete: onScanComplete)
            }
            .padding(AppLayout.contentPadding)
        }
    }
}

struct URLInputCard: View {
    let title: String
    let subtitle: String
    @Binding var urls: [String]
    let placeholder: String
    let onAddURL: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.itemSpacing) {
            HStack {
                Text(title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)

                Spacer()

                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)

                Button(action: onAddURL) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(AppColors.primary)
                }
                .buttonStyle(.plain)
            }

            ForEach(urls.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(placeholder, text: $urls[index])
                        .textFieldStyle(.roundedBorder)

                    if !urls[index].isEmpty {
                        Button {
                            urls[index] = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(AppColors.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .stroke(AppColors.border, lineWidth: 1)
        )
    }
}

struct ScanActionCard: View {
    @ObservedObject var viewModel: ScannerViewModel
    let onScanComplete: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if viewModel.isScanning || !viewModel.scanLogs.isEmpty {
                // Header: progress indicator + status + cancel
                HStack(spacing: 8) {
                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(viewModel.scanProgress)
                        .font(AppTypography.callout)
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    if viewModel.isScanning {
                        Button {
                            viewModel.cancelScan()
                        } label: {
                            Text("Cancel")
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.error)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Log window
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.scanLogs) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.timeDisplay)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(AppColors.textMuted)

                                    Text(entry.type.icon)
                                        .font(.system(size: 11))

                                    Text(entry.message)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(entry.type.color)
                                        .textSelection(.enabled)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 300)
                    .background(
                        RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                            .fill(AppColors.background)
                    )
                    .onChange(of: viewModel.scanLogs.count) { _ in
                        if let last = viewModel.scanLogs.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // Re-scan button when scan is complete
                if !viewModel.isScanning {
                    scanButton
                }
            } else {
                // No logs and not scanning - just show the button
                scanButton
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.error)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .stroke(AppColors.border, lineWidth: 1)
        )
    }

    private var scanButton: some View {
        Button {
            viewModel.startScan()
            Task {
                while viewModel.isScanning {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if !viewModel.scanResults.isEmpty {
                    await MainActor.run {
                        onScanComplete()
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass.circle.fill")
                Text("Start Scan (\(viewModel.allURLs.count) URL\(viewModel.allURLs.count == 1 ? "" : "s"))")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: AppLayout.buttonCornerRadius)
                    .fill(viewModel.canScan ? AppColors.primary : AppColors.textMuted)
            )
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canScan)
    }
}

// MARK: - Step 2: Select Courts (NEW)

struct SelectCourtsStep: View {
    let groupedByCourt: [String: [ScannerViewModel.VBLMatch]]
    @Binding var selectedCourts: Set<String>
    @Binding var searchText: String

    private var sortedCourts: [String] {
        let filtered = groupedByCourt.keys.filter {
            searchText.isEmpty || $0.lowercased().contains(searchText.lowercased())
        }
        return filtered.sorted { a, b in
            let numA = extractNumber(from: a)
            let numB = extractNumber(from: b)
            if let nA = numA, let nB = numB { return nA < nB }
            return a < b
        }
    }

    private var allSelected: Bool {
        sortedCourts.allSatisfy { selectedCourts.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Instruction text
            Text("Choose which courts have cameras. All matches are imported — unselected courts go to Standby.")
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, AppLayout.contentPadding)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Search and select all
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(AppColors.textMuted)
                    TextField("Search courts...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(AppTypography.body)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppColors.surfaceElevated)
                )
                .frame(maxWidth: 300)

                Spacer()

                Button {
                    if allSelected {
                        selectedCourts.removeAll()
                    } else {
                        selectedCourts = Set(sortedCourts)
                    }
                } label: {
                    Text(allSelected ? "None Have Cameras" : "All Have Cameras")
                        .font(AppTypography.callout)
                }
                .buttonStyle(.bordered)

                Text("\(selectedCourts.count) of \(groupedByCourt.count) courts with cameras")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }
            .padding(AppLayout.contentPadding)

            Divider().overlay(AppColors.border)

            // Court table
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sortedCourts, id: \.self) { courtName in
                        let matches = groupedByCourt[courtName] ?? []
                        let isSelected = selectedCourts.contains(courtName)

                        Button {
                            if isSelected {
                                selectedCourts.remove(courtName)
                            } else {
                                selectedCourts.insert(courtName)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 16))
                                    .foregroundColor(isSelected ? AppColors.primary : AppColors.textMuted)

                                Text("Court \(courtName)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppColors.textPrimary)

                                Spacer()

                                Text("\(matches.count) matches")
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textMuted)

                                // Type badges
                                let hasPool = matches.contains { $0.matchType?.lowercased().contains("pool") == true }
                                let hasBracket = matches.contains { $0.matchType?.lowercased().contains("bracket") == true }

                                if hasPool {
                                    Text("Pool")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(AppColors.info))
                                }
                                if hasBracket {
                                    Text("Bracket")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(AppColors.primary))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? AppColors.primary.opacity(0.1) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }

    private func extractNumber(from name: String) -> Int? {
        let digits = name.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
}

// MARK: - Step 3: Configure Output (Court Mapping)

struct CourtMappingStep: View {
    let groupedByCourt: [String: [ScannerViewModel.VBLMatch]]
    @Binding var courtAssignments: [String: Int]

    @StateObject private var mappingStore = CourtMappingStore.shared

    private var sortedCourts: [String] {
        groupedByCourt.keys.sorted { a, b in
            let numA = extractNumber(from: a)
            let numB = extractNumber(from: b)
            if let nA = numA, let nB = numB { return nA < nB }
            return a < b
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Button(action: autoAssignCourts) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Auto-Map")
                    }
                    .font(AppTypography.callout)
                }
                .buttonStyle(.bordered)
                .tint(AppColors.info)

                Button {
                    courtAssignments.removeAll()
                } label: {
                    Text("Reset")
                        .font(AppTypography.callout)
                }
                .buttonStyle(.bordered)

                Spacer()

                let assignedCount = courtAssignments.values.filter { $0 > 0 }.count
                Text("\(assignedCount) of \(sortedCourts.count) mapped")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }
            .padding(.horizontal, AppLayout.contentPadding)
            .padding(.vertical, 12)

            Divider().overlay(AppColors.border)

            // Mapping table
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sortedCourts, id: \.self) { courtName in
                        CourtMappingRow(
                            courtName: courtName,
                            matchCount: groupedByCourt[courtName]?.count ?? 0,
                            selectedCamera: Binding(
                                get: { courtAssignments[courtName] ?? 0 },
                                set: { courtAssignments[courtName] = $0 }
                            )
                        )
                    }
                }
                .padding(AppLayout.contentPadding)
            }
        }
        .onAppear {
            for courtName in groupedByCourt.keys {
                if courtAssignments[courtName] == nil,
                   let existingCamera = mappingStore.cameraId(for: courtName) {
                    courtAssignments[courtName] = existingCamera
                }
            }
        }
    }

    private func autoAssignCourts() {
        let priorityPatterns = ["stadium", "center", "main", "feature", "show"]
        var priorityCourts: [String] = []
        var numberedCourts: [String] = []

        for courtName in sortedCourts {
            let lowerName = courtName.lowercased()
            if priorityPatterns.contains(where: { lowerName.contains($0) }) {
                priorityCourts.append(courtName)
            } else {
                numberedCourts.append(courtName)
            }
        }

        for courtName in priorityCourts {
            courtAssignments[courtName] = 1
        }

        // If no priority courts, first numbered court gets camera 1 (Core 1)
        let startCamera = priorityCourts.isEmpty && !numberedCourts.isEmpty ? 1 : 2
        for (index, courtName) in numberedCourts.enumerated() {
            courtAssignments[courtName] = min(startCamera + index, AppConfig.maxCourts)
        }
    }

    private func extractNumber(from name: String) -> Int? {
        let digits = name.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
}

struct CourtMappingRow: View {
    let courtName: String
    let matchCount: Int
    @Binding var selectedCamera: Int

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Court \(courtName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)

                Text("\(matchCount) matches")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }

            Spacer()

            Image(systemName: "arrow.right")
                .foregroundColor(AppColors.textMuted)

            Picker("Camera", selection: $selectedCamera) {
                Text("Not Assigned").tag(0)
                ForEach(1...AppConfig.maxCourts, id: \.self) { cameraId in
                    Text(CourtNaming.displayName(for: cameraId)).tag(cameraId)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .tint(selectedCamera > 0 ? AppColors.success : AppColors.textMuted)
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(selectedCamera > 0 ? AppColors.success.opacity(0.08) : AppColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .stroke(selectedCamera > 0 ? AppColors.success.opacity(0.3) : AppColors.border, lineWidth: 1)
        )
    }
}

// MARK: - Step 4: Kanban Queue Management

struct KanbanQueueStep: View {
    let scanResults: [ScannerViewModel.VBLMatch]
    var liveCourts: Set<String> = []
    @Binding var assignments: [UUID: Int]
    let onImport: () -> Void

    @State private var autoAssignDone = false

    private var unassignedMatches: [ScannerViewModel.VBLMatch] {
        scanResults.filter { (assignments[$0.id] ?? 0) == 0 }
    }

    private func matchesForCamera(_ cameraId: Int) -> [ScannerViewModel.VBLMatch] {
        scanResults.filter { assignments[$0.id] == cameraId }
    }

    private var sortedCourtNames: [String] {
        let grouped = Dictionary(grouping: scanResults) { $0.courtDisplay }
        return grouped.keys.sorted { a, b in
            let numA = extractNumber(from: a)
            let numB = extractNumber(from: b)
            if let nA = numA, let nB = numB { return nA < nB }
            return a < b
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button {
                    autoAssignAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Auto-Assign All")
                    }
                    .font(AppTypography.callout)
                }
                .buttonStyle(.bordered)
                .tint(AppColors.info)

                Button {
                    for match in scanResults {
                        assignments[match.id] = 0
                    }
                } label: {
                    Text("Clear All")
                        .font(AppTypography.callout)
                }
                .buttonStyle(.bordered)

                Spacer()

                let assignedCount = assignments.values.filter { $0 > 0 }.count
                Text("\(assignedCount) of \(scanResults.count) assigned")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }
            .padding(.horizontal, AppLayout.contentPadding)
            .padding(.vertical, 12)

            Divider().overlay(AppColors.border)

            // Two-panel layout
            HSplitView {
                // Left panel — All Matches
                sourceMatchPanel
                    .frame(minWidth: 620, idealWidth: 860)

                // Right panel — Camera Queues
                cameraQueuePanel
                    .frame(minWidth: 430, idealWidth: 560)
            }
        }
        .onAppear {
            if !autoAssignDone {
                autoAssignAll()
                autoAssignDone = true
            }
        }
    }

    // MARK: - Left Panel: All Matches

    private var sourceMatchPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All Matches")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Text("\(scanResults.count) total")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppColors.surfaceElevated)

            Divider().overlay(AppColors.border)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedCourtNames, id: \.self) { courtName in
                        let courtMatches = scanResults.filter { $0.courtDisplay == courtName }
                        let isLive = liveCourts.contains(courtName)

                        // Section header
                        HStack(spacing: 8) {
                            Image(systemName: isLive ? "video.fill" : "video.slash.fill")
                                .font(.system(size: 13))
                                .foregroundColor(isLive ? AppColors.success : AppColors.textMuted)

                            Text("Court \(courtName)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(AppColors.textPrimary)

                            Text("\(courtMatches.count) matches")
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textMuted)

                            if !isLive {
                                Text("No Camera")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(AppColors.warning)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(AppColors.warning.opacity(0.2)))
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(AppColors.surface)

                        // Match cards
                        ForEach(courtMatches, id: \.id) { match in
                            SourceMatchCard(
                                match: match,
                                currentCamera: assignments[match.id] ?? 0,
                                onAssign: { cameraId in
                                    assignments[match.id] = cameraId
                                }
                            )
                        }

                        Divider().overlay(AppColors.border)
                    }
                }
            }
        }
        .background(AppColors.background)
    }

    // MARK: - Right Panel: Camera Queues

    private var cameraQueuePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Camera Queues")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppColors.surfaceElevated)

            Divider().overlay(AppColors.border)

            ScrollView {
                LazyVStack(spacing: 8) {
                    // Camera sections
                    ForEach(1...AppConfig.maxCourts, id: \.self) { cameraId in
                        let cameraMatches = matchesForCamera(cameraId)
                        if !cameraMatches.isEmpty || cameraId <= 4 {
                            CameraQueueSection(
                                cameraId: cameraId,
                                matches: cameraMatches,
                                onRemove: { matchId in
                                    assignments[matchId] = 0
                                }
                            )
                        }
                    }

                    // Standby section
                    if !unassignedMatches.isEmpty {
                        CameraQueueSection(
                            cameraId: 0,
                            matches: unassignedMatches,
                            onRemove: { _ in }
                        )
                    }
                }
                .padding(12)
            }
        }
        .background(AppColors.background)
    }

    private func autoAssignAll() {
        let priorityCourtPatterns = ["stadium", "center", "main", "feature", "show"]
        let eligibleMatches = scanResults.filter { liveCourts.contains($0.courtDisplay) }
        let grouped = Dictionary(grouping: eligibleMatches) { $0.courtDisplay }
        var priorityCourts: [String] = []
        var numberedCourts: [(name: String, number: Int)] = []
        var otherCourts: [String] = []

        // Any matches from courts without cameras must stay in Standby.
        for match in scanResults where !liveCourts.contains(match.courtDisplay) {
            assignments[match.id] = 0
        }

        for courtName in grouped.keys {
            let lowerName = courtName.lowercased()
            if priorityCourtPatterns.contains(where: { lowerName.contains($0) }) {
                priorityCourts.append(courtName)
            } else if let num = extractNumber(from: courtName) {
                numberedCourts.append((name: courtName, number: num))
            } else {
                otherCourts.append(courtName)
            }
        }

        numberedCourts.sort { $0.number < $1.number }

        for courtName in priorityCourts {
            if let matches = grouped[courtName] {
                for match in matches { assignments[match.id] = 1 }
            }
        }

        // If no priority courts, first numbered court gets camera 1 (Core 1)
        let numberedStart = priorityCourts.isEmpty && !numberedCourts.isEmpty ? 1 : 2
        for (index, court) in numberedCourts.enumerated() {
            let overlayId = min(numberedStart + index, AppConfig.maxCourts)
            if let matches = grouped[court.name] {
                for match in matches { assignments[match.id] = overlayId }
            }
        }

        let nextStart = numberedCourts.count + numberedStart
        for (index, courtName) in otherCourts.enumerated() {
            let overlayId = min(nextStart + index, AppConfig.maxCourts)
            if let matches = grouped[courtName] {
                for match in matches { assignments[match.id] = overlayId }
            }
        }
    }

    private func extractNumber(from name: String) -> Int? {
        let digits = name.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
}

struct KanbanColumn: View {
    let title: String
    let cameraId: Int
    let matches: [ScannerViewModel.VBLMatch]
    @Binding var assignments: [UUID: Int]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Column header
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)

                Spacer()

                Text("\(matches.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(color.opacity(0.15))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppColors.surfaceElevated)
            .cornerRadius(8)

            // Match cards
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(matches, id: \.id) { match in
                        KanbanMatchCard(match: match)
                            .draggable(match.id.uuidString) {
                                Text(match.displayName)
                                    .padding(8)
                                    .background(AppColors.surface)
                                    .cornerRadius(6)
                            }
                    }
                }
            }
        }
        .frame(width: 220)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AppColors.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppColors.border, lineWidth: 1)
        )
        .dropDestination(for: String.self) { items, _ in
            for item in items {
                if let uuid = UUID(uuidString: item) {
                    assignments[uuid] = cameraId
                }
            }
            return true
        }
    }
}

struct KanbanMatchCard: View {
    let match: ScannerViewModel.VBLMatch
    
    private var matchupDisplay: String {
        compactMatchupText(for: match)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Teams
            Text(matchupDisplay)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let matchNum = match.matchNumber {
                    Text("M\(matchNum)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(AppColors.primary)
                }

                if let type = match.matchType {
                    let isPool = type.lowercased().contains("pool")
                    Text(isPool ? "Pool" : "Bracket")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isPool ? AppColors.info : AppColors.primary))
                }

                Spacer()

                if !match.timeDisplay.isEmpty {
                    Text(match.timeDisplay)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(AppColors.textMuted)
                }
            }

            HStack(spacing: 8) {
                Text("Ct \(match.courtDisplay)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AppColors.warning))

                if let day = match.startDate, !day.isEmpty {
                    Text(day)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(KanbanMatchCard.dayColor(for: day)))
                }

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppColors.border, lineWidth: 1)
        )
    }

    static func dayColor(for day: String) -> Color {
        switch day.lowercased().prefix(3) {
        case "sat": return AppColors.info
        case "sun": return AppColors.warning
        case "fri": return AppColors.success
        case "thu": return Color.purple
        default: return AppColors.textMuted
        }
    }
}

// MARK: - Source Match Card (Left Panel)

struct SourceMatchCard: View {
    let match: ScannerViewModel.VBLMatch
    let currentCamera: Int
    let onAssign: (Int) -> Void
    
    private var matchupDisplay: String {
        compactMatchupText(for: match)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Match info
            VStack(alignment: .leading, spacing: 7) {
                Text(matchupDisplay)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let matchNum = match.matchNumber {
                        Text("M\(matchNum)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(AppColors.primary)
                    }

                    Text("Ct \(match.courtDisplay)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AppColors.warning))

                    if let day = match.startDate, !day.isEmpty {
                        Text(day)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(KanbanMatchCard.dayColor(for: day)))
                    }

                    if !match.timeDisplay.isEmpty {
                        Text(match.timeDisplay)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(AppColors.textMuted)
                    }

                    if let type = match.matchType {
                        let isPool = type.lowercased().contains("pool")
                        Text(isPool ? "Pool" : "Bracket")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(isPool ? AppColors.info : AppColors.primary))
                    }
                }
            }

            Spacer()

            // Camera picker
            Picker("", selection: Binding(
                get: { currentCamera },
                set: { onAssign($0) }
            )) {
                Text("Standby").tag(0)
                ForEach(1...AppConfig.maxCourts, id: \.self) { cameraId in
                    Text(CourtNaming.displayName(for: cameraId)).tag(cameraId)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 145)
            .tint(currentCamera > 0 ? AppColors.success : AppColors.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(currentCamera > 0 ? AppColors.success.opacity(0.05) : Color.clear)
    }
}

// MARK: - Camera Queue Section (Right Panel)

struct CameraQueueSection: View {
    let cameraId: Int
    let matches: [ScannerViewModel.VBLMatch]
    let onRemove: (UUID) -> Void

    private var sectionTitle: String {
        cameraId == 0 ? "Standby" : CourtNaming.displayName(for: cameraId)
    }

    private var sectionColor: Color {
        cameraId == 0 ? AppColors.textMuted : AppColors.primary
    }

    var body: some View {
        DisclosureGroup {
            VStack(spacing: 4) {
                ForEach(matches, id: \.id) { match in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(compactMatchupText(for: match))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                if let matchNum = match.matchNumber {
                                    Text("M\(matchNum)")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(AppColors.primary)
                                }
                                Text("Ct \(match.courtDisplay)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(AppColors.warning))
                                
                                if let day = match.startDate, !day.isEmpty {
                                    Text(day)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(KanbanMatchCard.dayColor(for: day)))
                                }
                                
                                if !match.timeDisplay.isEmpty {
                                    Text(match.timeDisplay)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(AppColors.textMuted)
                                }
                            }
                        }

                        Spacer()

                        if cameraId > 0 {
                            Button {
                                onRemove(match.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(AppColors.error.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Remove to Standby")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(AppColors.surfaceElevated)
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: cameraId == 0 ? "moon.zzz.fill" : "video.fill")
                    .font(.system(size: 12))
                    .foregroundColor(sectionColor)

                Text(sectionTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)

                Spacer()

                Text("\(matches.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(sectionColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(sectionColor.opacity(0.15)))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppColors.border, lineWidth: 1)
        )
    }
}

private func compactMatchupText(for match: ScannerViewModel.VBLMatch) -> String {
    if let t1 = match.team1?.trimmingCharacters(in: .whitespacesAndNewlines),
       let t2 = match.team2?.trimmingCharacters(in: .whitespacesAndNewlines),
       !t1.isEmpty,
       !t2.isEmpty {
        return "\(compactTeamName(t1)) vs \(compactTeamName(t2))"
    }
    
    return compactDisplayName(match.displayName)
}

private func compactDisplayName(_ value: String) -> String {
    let parts = value.components(separatedBy: " vs ")
    if parts.count == 2 {
        return "\(compactTeamName(parts[0])) vs \(compactTeamName(parts[1]))"
    }
    return value
}

private func compactTeamName(_ team: String) -> String {
    let trimmed = team.trimmingCharacters(in: .whitespacesAndNewlines)
    if isPlaceholderTeam(trimmed) {
        return trimmed
    }
    
    let players = trimmed
        .components(separatedBy: "/")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    
    if players.count >= 2 {
        return players.map(lastName).joined(separator: "/")
    }
    
    return lastName(trimmed)
}

private func lastName(_ player: String) -> String {
    let cleaned = player
        .replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    
    let parts = cleaned.split(whereSeparator: \.isWhitespace)
    if let last = parts.last {
        return String(last)
    }
    
    return cleaned
}

private func isPlaceholderTeam(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.contains("winner")
        || lower.contains("loser")
        || lower.contains("match ")
        || lower.contains("team ")
        || lower == "tbd"
}
