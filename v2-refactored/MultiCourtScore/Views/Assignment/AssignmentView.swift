//
//  AssignmentView.swift
//  MultiCourtScore v2
//
//  Match-to-court assignment interface
//

import SwiftUI

struct AssignmentView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var matchAssignments: [UUID: Int] = [:]
    
    private var scanResults: [ScannerViewModel.VBLMatch] {
        appViewModel.scannerViewModel.scanResults
    }
    
    private var groupedByCourt: [String: [ScannerViewModel.VBLMatch]] {
        appViewModel.scannerViewModel.groupedByCourt
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            AssignmentHeader(
                matchCount: scanResults.count,
                onDone: { dismiss() },
                onAutoAssign: autoAssignMatches,
                onImport: importAssignedMatches
            )
            
            if scanResults.isEmpty {
                // Empty state
                EmptyAssignmentState()
            } else {
                // Assignment grid
                ScrollView {
                    LazyVStack(spacing: AppLayout.cardSpacing) {
                        ForEach(groupedByCourt.keys.sorted(), id: \.self) { courtName in
                            if let matches = groupedByCourt[courtName] {
                                CourtAssignmentSection(
                                    courtName: courtName,
                                    matches: matches,
                                    assignments: $matchAssignments
                                )
                            }
                        }
                    }
                    .padding(AppLayout.contentPadding)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(AppColors.background)
        .onAppear {
            initializeAssignments()
        }
    }
    
    // MARK: - Actions
    
    private func initializeAssignments() {
        for match in scanResults {
            matchAssignments[match.id] = 0
        }
    }
    
    private func autoAssignMatches() {
        let sortedCourts = groupedByCourt.keys.sorted()
        
        for (index, courtName) in sortedCourts.enumerated() {
            // Try to extract court number, fallback to sequential
            let courtNumber = extractCourtNumber(from: courtName) ?? (index + 1)
            let overlayId = min(courtNumber, AppConfig.maxCourts)
            
            if let matches = groupedByCourt[courtName] {
                for match in matches {
                    matchAssignments[match.id] = overlayId
                }
            }
        }
    }
    
    private func importAssignedMatches() {
        // Group matches by assigned overlay
        var matchesByOverlay: [Int: [ScannerViewModel.VBLMatch]] = [:]
        
        for match in scanResults {
            guard let overlayId = matchAssignments[match.id], overlayId > 0 else { continue }
            
            if matchesByOverlay[overlayId] == nil {
                matchesByOverlay[overlayId] = []
            }
            matchesByOverlay[overlayId]?.append(match)
        }
        
        // Convert and import to each court
        for (overlayId, matches) in matchesByOverlay {
            let matchItems = appViewModel.scannerViewModel.createMatchItems(from: matches)
            appViewModel.replaceQueue(overlayId, with: matchItems)
        }
        
        dismiss()
    }
    
    private func extractCourtNumber(from name: String) -> Int? {
        let digits = name.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
}

// MARK: - Header
struct AssignmentHeader: View {
    let matchCount: Int
    let onDone: () -> Void
    let onAutoAssign: () -> Void
    let onImport: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assign Matches")
                    .font(AppTypography.title)
                    .foregroundColor(AppColors.textPrimary)
                
                Text("\(matchCount) matches available for assignment")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button {
                    onAutoAssign()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text("Auto Assign")
                    }
                }
                .buttonStyle(.bordered)
                
                Button {
                    onImport()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Import to Courts")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.success)
                
                Button("Done") { onDone() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(AppLayout.contentPadding)
        .background(AppColors.surface)
    }
}

// MARK: - Empty State
struct EmptyAssignmentState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(AppColors.textMuted)
            
            Text("No scan data available")
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textSecondary)
            
            Text("Run a VBL scan first to get match data for assignment")
                .font(AppTypography.body)
                .foregroundColor(AppColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Court Assignment Section
struct CourtAssignmentSection: View {
    let courtName: String
    let matches: [ScannerViewModel.VBLMatch]
    @Binding var assignments: [UUID: Int]
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.itemSpacing) {
            // Section header with bulk assign
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Court \(courtName)")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)
                    
                    Text("\(matches.count) match\(matches.count == 1 ? "" : "es")")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textMuted)
                }
                
                Spacer()
                
                // Bulk assign menu
                Menu {
                    ForEach(1...AppConfig.maxCourts, id: \.self) { overlayId in
                        Button(CourtNaming.displayName(for: overlayId)) {
                            for match in matches {
                                assignments[match.id] = overlayId
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Assign All")
                            .font(AppTypography.callout)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(AppColors.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                            .fill(AppColors.primary.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
            
            // Match cards grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppLayout.smallSpacing) {
                ForEach(matches) { match in
                    MatchAssignmentCard(
                        match: match,
                        assignedOverlay: Binding(
                            get: { assignments[match.id] ?? 0 },
                            set: { assignments[match.id] = $0 }
                        )
                    )
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

// MARK: - Match Assignment Card
struct MatchAssignmentCard: View {
    let match: ScannerViewModel.VBLMatch
    @Binding var assignedOverlay: Int
    
    private var isAssigned: Bool { assignedOverlay > 0 }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Match name
            Text(match.displayName)
                .font(AppTypography.callout)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(2)
            
            // Match type badge
            if let matchType = match.matchType {
                HStack(spacing: 4) {
                    Text(matchType)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(matchType.contains("Pool") ? AppColors.info : AppColors.primary)
                        )
                    
                    if let detail = match.typeDetail {
                        Text(detail)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textMuted)
                    }
                }
            }
            
            // Time and API status
            HStack {
                if let time = match.startTime {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(time)
                            .font(AppTypography.caption)
                    }
                    .foregroundColor(AppColors.textMuted)
                }
                
                Spacer()
                
                Image(systemName: match.hasAPIURL ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(match.hasAPIURL ? AppColors.success : AppColors.error)
            }
            
            // Assignment dropdown
            Menu {
                Button("Unassigned") { assignedOverlay = 0 }
                Divider()
                ForEach(1...AppConfig.maxCourts, id: \.self) { overlayId in
                    Button(CourtNaming.displayName(for: overlayId)) {
                        assignedOverlay = overlayId
                    }
                }
            } label: {
                HStack {
                    Text(isAssigned ? CourtNaming.displayName(for: assignedOverlay) : "Select Overlay...")
                        .font(AppTypography.caption)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundColor(isAssigned ? AppColors.textPrimary : AppColors.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                        .fill(isAssigned ? AppColors.success.opacity(0.1) : AppColors.surfaceHover)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                        .stroke(isAssigned ? AppColors.success.opacity(0.3) : AppColors.textMuted.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(AppLayout.itemSpacing)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                .fill(AppColors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                .stroke(isAssigned ? AppColors.success.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

#Preview {
    AssignmentView()
        .environmentObject(AppViewModel())
}
