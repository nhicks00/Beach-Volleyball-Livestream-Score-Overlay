//
//  ScanWorkflowView.swift
//  MultiCourtScore v2
//
//  Unified VBL scanning and assignment workflow
//

import SwiftUI

enum ScanWorkflowStep: Int, CaseIterable {
    case enterURLs = 0
    case scanResults = 1
    case assign = 2
    
    var title: String {
        switch self {
        case .enterURLs: return "Enter URLs"
        case .scanResults: return "Review Results"
        case .assign: return "Assign to Courts"
        }
    }
    
    var icon: String {
        switch self {
        case .enterURLs: return "link.badge.plus"
        case .scanResults: return "doc.text.magnifyingglass"
        case .assign: return "arrow.triangle.branch"
        }
    }
}

struct ScanWorkflowView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentStep: ScanWorkflowStep = .enterURLs
    @State private var matchAssignments: [UUID: Int] = [:]
    
    private var viewModel: ScannerViewModel { appViewModel.scannerViewModel }
    
    private var scanResults: [ScannerViewModel.VBLMatch] { viewModel.scanResults }
    private var groupedByCourt: [String: [ScannerViewModel.VBLMatch]] { viewModel.groupedByCourt }
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress Header
            WorkflowHeader(
                currentStep: currentStep,
                onClose: { dismiss() }
            )
            
            // Step Content
            Group {
                switch currentStep {
                case .enterURLs:
                    URLEntryStep(
                        viewModel: viewModel,
                        onScanComplete: { advanceToResults() }
                    )
                case .scanResults:
                    ScanResultsStep(
                        viewModel: viewModel,
                        onProceed: { advanceToAssign() },
                        onBack: { currentStep = .enterURLs }
                    )
                case .assign:
                    AssignmentStep(
                        scanResults: scanResults,
                        groupedByCourt: groupedByCourt,
                        assignments: $matchAssignments,
                        onAutoAssign: autoAssignMatches,
                        onImport: importAndClose,
                        onBack: { currentStep = .scanResults }
                    )
                }
            }
        }
        .frame(minWidth: 800, minHeight: 650)
        .background(AppColors.background)
        .onAppear {
            // If we already have results, start at results step
            if !viewModel.scanResults.isEmpty {
                currentStep = .scanResults
            }
        }
    }
    
    // MARK: - Navigation
    
    private func advanceToResults() {
        currentStep = .scanResults
    }
    
    private func advanceToAssign() {
        initializeAssignments()
        currentStep = .assign
    }
    
    // MARK: - Assignment Logic
    
    private func initializeAssignments() {
        for match in scanResults {
            matchAssignments[match.id] = 0
        }
    }
    
    private func autoAssignMatches() {
        let priorityCourtPatterns = ["stadium", "center", "main", "feature", "show"]
        
        var priorityCourts: [String] = []
        var numberedCourts: [(name: String, number: Int)] = []
        var otherCourts: [String] = []
        
        for courtName in groupedByCourt.keys {
            let lowerName = courtName.lowercased()
            
            if priorityCourtPatterns.contains(where: { lowerName.contains($0) }) {
                priorityCourts.append(courtName)
            } else if let num = extractCourtNumber(from: courtName) {
                numberedCourts.append((name: courtName, number: num))
            } else {
                otherCourts.append(courtName)
            }
        }
        
        numberedCourts.sort { $0.number < $1.number }
        
        for courtName in priorityCourts {
            if let matches = groupedByCourt[courtName] {
                for match in matches {
                    matchAssignments[match.id] = 1
                }
            }
        }
        
        for (index, court) in numberedCourts.enumerated() {
            let overlayId = min(index + 2, AppConfig.maxCourts)
            if let matches = groupedByCourt[court.name] {
                for match in matches {
                    matchAssignments[match.id] = overlayId
                }
            }
        }
        
        let nextOverlayStart = numberedCourts.count + 2
        for (index, courtName) in otherCourts.enumerated() {
            let overlayId = min(nextOverlayStart + index, AppConfig.maxCourts)
            if let matches = groupedByCourt[courtName] {
                for match in matches {
                    matchAssignments[match.id] = overlayId
                }
            }
        }
    }
    
    private func importAndClose() {
        var matchesByOverlay: [Int: [ScannerViewModel.VBLMatch]] = [:]
        
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
                
                // Secondary sort by index (original order)
                return a.index < b.index
            }
            
            let matchItems = viewModel.createMatchItems(from: sortedMatches)
            
            // Auto-detect start index (skip completed matches)
            // TODO: Update scraper to return match scores/status to enable this
            let startIndex = 0 // findFirstLiveMatchIndex(matches: sortedMatches)
            
            appViewModel.replaceQueue(overlayId, with: matchItems, startIndex: startIndex)
        }
        
        dismiss()
    }
    
    private func findFirstLiveMatchIndex(matches: [ScannerViewModel.VBLMatch]) -> Int {
        // Placeholder until scraper returns scores/status
        return 0
    }
    
    private func extractCourtNumber(from name: String) -> Int? {
        let digits = name.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
}

// MARK: - Workflow Header

struct WorkflowHeader: View {
    let currentStep: ScanWorkflowStep
    let onClose: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Title and close button
            HStack {
                Text("Scan & Assign Matches")
                    .font(AppTypography.title)
                    .foregroundColor(AppColors.textPrimary)
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(AppColors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppLayout.contentPadding)
            .padding(.top, AppLayout.contentPadding)
            .padding(.bottom, 12)
            
            // Step indicators
            HStack(spacing: 0) {
                ForEach(ScanWorkflowStep.allCases, id: \.rawValue) { step in
                    StepIndicator(
                        step: step,
                        isActive: step == currentStep,
                        isComplete: step.rawValue < currentStep.rawValue
                    )
                    
                    if step.rawValue < ScanWorkflowStep.allCases.count - 1 {
                        StepConnector(isComplete: step.rawValue < currentStep.rawValue)
                    }
                }
            }
            .padding(.horizontal, AppLayout.contentPadding)
            .padding(.bottom, 16)
        }
        .background(AppColors.surface)
    }
}

struct StepIndicator: View {
    let step: ScanWorkflowStep
    let isActive: Bool
    let isComplete: Bool
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isActive ? AppColors.primary : (isComplete ? AppColors.success : AppColors.surfaceHover))
                    .frame(width: 36, height: 36)
                
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 14))
                        .foregroundColor(isActive ? .white : AppColors.textMuted)
                }
            }
            
            Text(step.title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? AppColors.textPrimary : AppColors.textMuted)
        }
    }
}

struct StepConnector: View {
    let isComplete: Bool
    
    var body: some View {
        Rectangle()
            .fill(isComplete ? AppColors.success : AppColors.surfaceHover)
            .frame(height: 2)
            .frame(maxWidth: 80)
            .padding(.bottom, 24)
    }
}

// MARK: - Step 1: URL Entry

struct URLEntryStep: View {
    @ObservedObject var viewModel: ScannerViewModel
    let onScanComplete: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(spacing: AppLayout.sectionSpacing) {
                // Bracket URLs
                URLInputCard(
                    title: "Bracket URLs",
                    subtitle: "\(viewModel.bracketURLs.filter { !$0.isEmpty }.count) entered",
                    urls: $viewModel.bracketURLs,
                    placeholder: "https://volleyballlife.com/.../brackets",
                    onAddURL: { viewModel.bracketURLs.append("") }
                )
                
                // Pool URLs
                URLInputCard(
                    title: "Pool URLs",
                    subtitle: "\(viewModel.poolURLs.filter { !$0.isEmpty }.count) entered",
                    urls: $viewModel.poolURLs,
                    placeholder: "https://volleyballlife.com/.../pools",
                    onAddURL: { viewModel.poolURLs.append("") }
                )
                
                // Scan Button
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
    }
}

struct ScanActionCard: View {
    @ObservedObject var viewModel: ScannerViewModel
    let onScanComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            if viewModel.isScanning {
                // Progress
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    
                    Text(viewModel.scanProgress)
                        .font(AppTypography.callout)
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.vertical, 20)
            } else {
                // Scan button
                Button {
                    viewModel.startScan()
                    
                    // Monitor for completion
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
                        Text("Scan \(viewModel.allURLs.count) URL\(viewModel.allURLs.count == 1 ? "" : "s")")
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
    }
}

// MARK: - Step 2: Scan Results

struct ScanResultsStep: View {
    @ObservedObject var viewModel: ScannerViewModel
    let onProceed: () -> Void
    let onBack: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Results summary
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(viewModel.scanResults.count) Matches Found")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)
                    
                    Text("From \(viewModel.groupedByCourt.keys.count) courts")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textMuted)
                }
                
                Spacer()
                
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(AppTypography.callout)
                }
                .buttonStyle(.bordered)
                
                Button(action: onProceed) {
                    HStack(spacing: 4) {
                        Text("Proceed to Assign")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.success)
            }
            .padding(AppLayout.contentPadding)
            .background(AppColors.surface)
            
            // Results list
            ScrollView {
                LazyVStack(spacing: AppLayout.itemSpacing) {
                    ForEach(Array(viewModel.groupedByCourt.keys.sorted()), id: \.self) { courtName in
                        if let matches = viewModel.groupedByCourt[courtName] {
                            CourtResultsCard(courtName: courtName, matches: matches)
                        }
                    }
                }
                .padding(AppLayout.contentPadding)
            }
        }
    }
}

struct CourtResultsCard: View {
    let courtName: String
    let matches: [ScannerViewModel.VBLMatch]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Court \(courtName)")
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                
                Spacer()
                
                Text("\(matches.count) matches")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }
            
            ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                HStack {
                    Text("\(match.team1 ?? "TBD") vs \(match.team2 ?? "TBD")")
                        .font(AppTypography.body)
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if !match.timeDisplay.isEmpty {
                        Text(match.timeDisplay)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textMuted)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surface)
        )
    }
}

// MARK: - Step 3: Assignment

struct AssignmentStep: View {
    let scanResults: [ScannerViewModel.VBLMatch]
    let groupedByCourt: [String: [ScannerViewModel.VBLMatch]]
    @Binding var assignments: [UUID: Int]
    let onAutoAssign: () -> Void
    let onImport: () -> Void
    let onBack: () -> Void
    
    private var assignedCount: Int {
        assignments.values.filter { $0 > 0 }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assign to Courts")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)
                    
                    Text("\(assignedCount) of \(scanResults.count) assigned")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textMuted)
                }
                
                Spacer()
                
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(AppTypography.callout)
                }
                .buttonStyle(.bordered)
                
                Button("Auto-Assign All") {
                    onAutoAssign()
                }
                .buttonStyle(.bordered)
                .tint(AppColors.info)
                
                Button(action: onImport) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import as Queue")
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.success)
                .disabled(assignedCount == 0)
            }
            .padding(AppLayout.contentPadding)
            .background(AppColors.surface)
            
            // Assignment list
            ScrollView {
                LazyVStack(spacing: AppLayout.itemSpacing) {
                    ForEach(Array(groupedByCourt.keys.sorted()), id: \.self) { courtName in
                        if let matches = groupedByCourt[courtName] {
                            CourtAssignmentCard(
                                courtName: courtName,
                                matches: matches,
                                assignments: $assignments
                            )
                        }
                    }
                }
                .padding(AppLayout.contentPadding)
            }
        }
    }
}

struct CourtAssignmentCard: View {
    let courtName: String
    let matches: [ScannerViewModel.VBLMatch]
    @Binding var assignments: [UUID: Int]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Court \(courtName)")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)
                    
                    Text("\(matches.count) matches")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textMuted)
                }
                
                Spacer()
                
                // Bulk assign picker
                Picker("Assign All", selection: Binding(
                    get: { assignments[matches.first?.id ?? UUID()] ?? 0 },
                    set: { newValue in
                        for match in matches {
                            assignments[match.id] = newValue
                        }
                    }
                )) {
                    Text("Not Assigned").tag(0)
                    ForEach(1...AppConfig.maxCourts, id: \.self) { id in
                        Text(CourtNaming.displayName(for: id)).tag(id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }
            
            Divider()
            
            ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                HStack {
                    Text("\(match.team1 ?? "TBD") vs \(match.team2 ?? "TBD")")
                        .font(AppTypography.body)
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Picker("", selection: Binding(
                        get: { assignments[match.id] ?? 0 },
                        set: { assignments[match.id] = $0 }
                    )) {
                        Text("—").tag(0)
                        ForEach(1...AppConfig.maxCourts, id: \.self) { id in
                            Text(CourtNaming.shortName(for: id)).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
            }
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surface)
        )
    }
}
