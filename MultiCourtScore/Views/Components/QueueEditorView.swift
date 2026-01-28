//
//  QueueEditorView.swift
//  MultiCourtScore v2
//
//  Edit match queue for a specific court
//

import SwiftUI

struct QueueEditorView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    let courtId: Int
    
    @State private var rows: [QueueRow] = []
    @State private var errorMessage: String?
    
    private var court: Court? {
        appViewModel.court(for: courtId)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            QueueEditorHeader(
                courtName: court?.displayName ?? "Unknown",
                onSave: save,
                onCancel: { dismiss() },
                hasError: errorMessage != nil
            )
            
            // Instructions
            Text("Add API URLs and optional labels for each match. Matches will play in order from top to bottom.")
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, AppLayout.contentPadding)
                .padding(.top, AppLayout.itemSpacing)
            
            // Queue list
            List {
                ForEach($rows) { $row in
                    QueueRowEditor(
                        row: $row,
                        onMoveUp: { moveRow(row, direction: -1) },
                        onMoveDown: { moveRow(row, direction: 1) },
                        onDelete: { deleteRow(row) },
                        isFirst: rows.first?.id == row.id,
                        isLast: rows.last?.id == row.id
                    )
                    .listRowBackground(AppColors.surfaceElevated)
                }
                .onMove { from, to in
                    rows.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            
            // Bottom toolbar
            QueueEditorToolbar(
                rowCount: rows.count,
                validCount: rows.filter { $0.isValid }.count,
                errorMessage: errorMessage,
                onAddRow: { rows.append(QueueRow()) },
                onPasteRows: pasteRows,
                onClearAll: { rows.removeAll() }
            )
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(AppColors.background)
        .onAppear {
            loadQueue()
        }
    }
    
    // MARK: - Data Management
    
    private func loadQueue() {
        guard let court = court else { return }
        rows = court.queue.map { match in
            QueueRow(
                label: match.label ?? "",
                urlString: match.apiURL.absoluteString,
                team1: match.team1Name ?? "",
                team2: match.team2Name ?? "",
                team1Seed: match.team1Seed ?? "",
                team2Seed: match.team2Seed ?? "",
                matchNumber: match.matchNumber ?? "",
                scheduledTime: match.scheduledTime ?? "",
                startDate: match.startDate ?? "",
                matchType: match.matchType ?? "",
                typeDetail: match.typeDetail ?? "",
                courtNumber: match.courtNumber ?? "",
                physicalCourt: match.physicalCourt ?? "",
                setsToWin: match.setsToWin,
                pointsPerSet: match.pointsPerSet,
                pointCap: match.pointCap,
                formatText: match.formatText ?? ""
            )
        }
    }
    
    private func save() {
        let items = rows.compactMap { row -> MatchItem? in
            guard let url = URL(string: row.urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.hasPrefix("http") == true else {
                return nil
            }
            
            // Preserve ALL match metadata when saving
            return MatchItem(
                apiURL: url,
                label: row.label.isEmpty ? nil : row.label,
                team1Name: row.team1.isEmpty ? nil : row.team1,
                team2Name: row.team2.isEmpty ? nil : row.team2,
                team1Seed: row.team1Seed.isEmpty ? nil : row.team1Seed,
                team2Seed: row.team2Seed.isEmpty ? nil : row.team2Seed,
                matchType: row.matchType.isEmpty ? nil : row.matchType,
                typeDetail: row.typeDetail.isEmpty ? nil : row.typeDetail,
                scheduledTime: row.scheduledTime.isEmpty ? nil : row.scheduledTime,
                startDate: row.startDate.isEmpty ? nil : row.startDate,
                matchNumber: row.matchNumber.isEmpty ? nil : row.matchNumber,
                courtNumber: row.courtNumber.isEmpty ? nil : row.courtNumber,
                physicalCourt: row.physicalCourt.isEmpty ? nil : row.physicalCourt,
                setsToWin: row.setsToWin,
                pointsPerSet: row.pointsPerSet,
                pointCap: row.pointCap,
                formatText: row.formatText.isEmpty ? nil : row.formatText
            )
        }
        
        if items.count != rows.filter({ !$0.urlString.isEmpty }).count {
            errorMessage = "One or more URLs are invalid"
            return
        }
        
        errorMessage = nil
        appViewModel.replaceQueue(courtId, with: items)
        dismiss()
    }
    
    private func moveRow(_ row: QueueRow, direction: Int) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let newIndex = index + direction
        guard rows.indices.contains(newIndex) else { return }
        rows.swapAt(index, newIndex)
    }
    
    private func deleteRow(_ row: QueueRow) {
        rows.removeAll { $0.id == row.id }
    }
    
    private func pasteRows() {
        #if os(macOS)
        guard let clipboard = NSPasteboard.general.string(forType: .string) else { return }
        
        let newRows = clipboard
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> QueueRow in
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                return QueueRow(
                    label: parts.first?.trimmingCharacters(in: .whitespaces) ?? "",
                    urlString: (parts.count > 1 ? parts[1] : String(line)).trimmingCharacters(in: .whitespaces)
                )
            }
        
        rows.append(contentsOf: newRows)
        #endif
    }
}

// MARK: - Queue Row Model
struct QueueRow: Identifiable {
    let id = UUID()
    var label: String = ""
    var urlString: String = ""
    var team1: String = ""
    var team2: String = ""
    var team1Seed: String = ""
    var team2Seed: String = ""
    var matchNumber: String = ""
    var scheduledTime: String = ""
    var startDate: String = ""
    var matchType: String = ""      // "Pool Play" or "Bracket Play"
    var typeDetail: String = ""     // "Pool A", "Winners Bracket"
    var courtNumber: String = ""    // Original court number from VBL
    var physicalCourt: String = "" // VBL court name
    var setsToWin: Int? = nil
    var pointsPerSet: Int? = nil
    var pointCap: Int? = nil
    var formatText: String = ""
    
    /// Clean name by removing parenthetical content like "(FR 52nd)"
    private func cleanName(_ name: String) -> String {
        // Remove anything in parentheses
        name.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    
    /// Abbreviated team name: "Troy Field" -> "T. Field"
    private func abbreviateName(_ name: String) -> String {
        let players = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        
        let abbreviated = players.map { player -> String in
            // Clean parenthetical content first
            let cleanedPlayer = cleanName(player)
            let parts = cleanedPlayer.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { return cleanedPlayer }
            
            let firstName = parts[0]
            let lastName = parts[parts.count - 1]
            return "\(firstName.prefix(1)). \(lastName)"
        }
        
        return abbreviated.joined(separator: " / ")
    }
    
    
    /// Format team name with seed suffix (e.g., "T. Smith (1)")
    private func formatWithSeed(_ name: String, seed: String) -> String {
        guard !seed.isEmpty else { return name }
        return "\(name) (\(seed))"
    }

    var displayTitle: String {
        if !team1.isEmpty || !team2.isEmpty {
            let t1 = team1.isEmpty ? "TBD" : formatWithSeed(abbreviateName(team1), seed: team1Seed)
            let t2 = team2.isEmpty ? "TBD" : formatWithSeed(abbreviateName(team2), seed: team2Seed)
            return "\(t1) vs \(t2)"
        }

        // If we have a label, check if it's just a number
        if !label.isEmpty {
            // If label is just a number (e.g., "7"), convert to "Match 7"
            if let _ = Int(label.trimmingCharacters(in: .whitespaces)) {
                return "Match \(label)"
            }
            return label
        }

        return "New Match (Save to fetch details)"
    }
    
    /// Short match type label: "Pool" or "Bracket"
    /// Falls back to URL inspection if matchType field is empty
    var matchTypeLabel: String {
        // First check explicit matchType field
        if matchType.lowercased().contains("pool") {
            return "Pool"
        } else if matchType.lowercased().contains("bracket") {
            return "Bracket"
        }
        
        // Fallback: detect from URL pattern
        let urlLower = urlString.lowercased()
        if urlLower.contains("pool") || urlLower.contains("/pools/") {
            return "Pool"
        } else if urlLower.contains("bracket") {
            return "Bracket"
        }
        
        return ""
    }
    
    /// Match info for display on the right side
    var matchInfo: String {
        var parts: [String] = []
        if !matchTypeLabel.isEmpty {
            parts.append(matchTypeLabel)
        }
        if !matchNumber.isEmpty {
            parts.append("M\(matchNumber)")
        }

        // Combine Day + Time
        var timeStr = ""
        if !startDate.isEmpty {
            timeStr += startDate
        }
        if !scheduledTime.isEmpty {
            if !timeStr.isEmpty { timeStr += " " }
            timeStr += scheduledTime
        }
        if !timeStr.isEmpty {
            parts.append(timeStr)
        }

        // Add format info if non-default
        let formatStr = formatDisplay
        if !formatStr.isEmpty {
            parts.append(formatStr)
        }

        return parts.joined(separator: " • ")
    }

    /// Format display (e.g., "Bo3 21pts" or "Bo1 15/17")
    var formatDisplay: String {
        let sets = setsToWin ?? 2
        let points = pointsPerSet ?? 21
        let cap = pointCap

        // Don't show if using defaults
        if sets == 2 && points == 21 && cap == nil {
            return ""
        }

        var parts: [String] = []

        // Sets to win: "Bo1", "Bo3", "Bo5"
        let totalSets = sets * 2 - 1
        parts.append("Bo\(totalSets)")

        // Points: "21pts" or "15/17" if there's a cap
        if let cap = cap {
            parts.append("\(points)/\(cap)")
        } else if points != 21 {
            parts.append("\(points)pts")
        }

        return parts.joined(separator: " ")
    }
    
    var isValid: Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.scheme?.hasPrefix("http") == true
    }
}

// MARK: - Header
struct QueueEditorHeader: View {
    let courtName: String
    let onSave: () -> Void
    let onCancel: () -> Void
    let hasError: Bool
    
    var body: some View {
        HStack {
            Text("Edit Queue — \(courtName)")
                .font(AppTypography.title)
                .foregroundColor(AppColors.textPrimary)
            
            Spacer()
            
            Button("Cancel") { onCancel() }
                .buttonStyle(.bordered)
            
            Button("Save Queue") { onSave() }
                .buttonStyle(.borderedProminent)
                .tint(hasError ? AppColors.error : AppColors.success)
        }
        .padding(AppLayout.contentPadding)
        .background(AppColors.surface)
    }
}

// MARK: - Row Editor
struct QueueRowEditor: View {
    @Binding var row: QueueRow
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    let isFirst: Bool
    let isLast: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            
            // Main Content Area
            VStack(alignment: .leading, spacing: 6) {
                // Match Identity (Read-only)
                HStack {
                    Image(systemName: "sportscourt")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    Text(row.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                    
                    Spacer()
                    
                    // Match number and time on the right
                    if !row.matchInfo.isEmpty {
                        Text(row.matchInfo)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppColors.textMuted)
                    }
                }
                
                // Match type badge and URL
                HStack(spacing: 8) {
                    // Pool/Bracket badge
                    if !row.matchTypeLabel.isEmpty {
                        Text(row.matchTypeLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(row.matchTypeLabel == "Pool" ? AppColors.info : AppColors.primary)
                            )
                    }
                    
                    // URL Input
                    HStack(spacing: 4) {
                        Text("URL:")
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.textMuted)
                        TextField("https://api...", text: $row.urlString)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .padding(6)
                    .background(AppColors.surface)
                    .cornerRadius(4)
                }
            }
            
            Spacer()
            
            // Validity indicator
            Circle()
                .fill(row.isValid ? AppColors.success : (row.urlString.isEmpty ? AppColors.textMuted : AppColors.error))
                .frame(width: 8, height: 8)
            
            // Move buttons
            VStack(spacing: 2) {
                Button { onMoveUp() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 14)
                }
                .disabled(isFirst)
                .buttonStyle(.borderless)
                
                Button { onMoveDown() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 14)
                }
                .disabled(isLast)
                .buttonStyle(.borderless)
            }
            .background(AppColors.surface)
            .cornerRadius(4)
            
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash.fill")
                    .foregroundColor(AppColors.textMuted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Toolbar
struct QueueEditorToolbar: View {
    let rowCount: Int
    let validCount: Int
    let errorMessage: String?
    let onAddRow: () -> Void
    let onPasteRows: () -> Void
    let onClearAll: () -> Void
    
    var body: some View {
        HStack(spacing: AppLayout.itemSpacing) {
            Button {
                onAddRow()
            } label: {
                Label("Add Row", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.bordered)
            
            Button {
                onPasteRows()
            } label: {
                Label("Paste Rows", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            
            Button(role: .destructive) {
                onClearAll()
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            if let error = errorMessage {
                Text(error)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.error)
            }
            
            Text("\(validCount)/\(rowCount) valid")
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textMuted)
        }
        .padding(AppLayout.contentPadding)
        .background(AppColors.surface)
    }
}

#Preview {
    QueueEditorView(courtId: 1)
        .environmentObject(AppViewModel())
}
