//
//  QueueEditorView.swift
//  MultiCourtScore v2
//
//  Edit match queue for a specific court - Redesigned for better UX
//

import SwiftUI

struct QueueEditorView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let courtId: Int

    @State private var rows: [QueueRow] = []
    @State private var errorMessage: String?
    @State private var selectedRowId: UUID?

    private var court: Court? {
        appViewModel.court(for: courtId)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Main content
            HSplitView {
                // Queue list (left panel)
                queueList
                    .frame(minWidth: 500)

                // Detail panel (right panel) - shows selected match details
                detailPanel
                    .frame(minWidth: 300, maxWidth: 400)
            }

            // Bottom toolbar
            toolbar
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(AppColors.background)
        .onAppear {
            loadQueue()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            // Title with court name
            VStack(alignment: .leading, spacing: 2) {
                Text("Queue Editor")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)

                HStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .foregroundColor(AppColors.primary)
                    Text(court?.displayName ?? "Unknown Camera")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppColors.textSecondary)

                    Text("•")
                        .foregroundColor(AppColors.textMuted)

                    Text("\(rows.count) matches")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textMuted)
                }
            }

            Spacer()

            // Action buttons
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.large)

            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Save Queue")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(errorMessage != nil ? AppColors.error : AppColors.success)
            .controlSize(.large)
        }
        .padding(20)
        .background(AppColors.surface)
    }

    // MARK: - Queue List

    private var queueList: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Text("#")
                    .frame(width: 40)
                Text("Match")
                    .frame(minWidth: 200, alignment: .leading)
                Spacer()
                Text("Schedule")
                    .frame(width: 120, alignment: .center)
                Text("Actions")
                    .frame(width: 100, alignment: .center)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(AppColors.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppColors.surfaceElevated)

            Divider()

            // Match rows
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        QueueMatchRow(
                            index: index + 1,
                            row: Binding(
                                get: { rows[index] },
                                set: { rows[index] = $0 }
                            ),
                            isSelected: selectedRowId == row.id,
                            onSelect: { selectedRowId = row.id },
                            onMoveUp: { moveRow(at: index, direction: -1) },
                            onMoveDown: { moveRow(at: index, direction: 1) },
                            onDelete: { deleteRow(at: index) },
                            isFirst: index == 0,
                            isLast: index == rows.count - 1
                        )
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(AppColors.background)
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        VStack(spacing: 0) {
            // Panel header
            HStack {
                Text("Match Details")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
            }
            .padding(16)
            .background(AppColors.surfaceElevated)

            Divider()

            if let selectedId = selectedRowId,
               let index = rows.firstIndex(where: { $0.id == selectedId }) {
                // Show selected match details
                MatchDetailEditor(row: $rows[index])
            } else {
                // No selection placeholder
                VStack(spacing: 12) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 40))
                        .foregroundColor(AppColors.textMuted)
                    Text("Select a match to edit")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppColors.surface)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            // Add actions
            Button {
                rows.append(QueueRow())
                selectedRowId = rows.last?.id
            } label: {
                Label("Add Match", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.bordered)

            Button {
                pasteRows()
            } label: {
                Label("Paste URLs", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)

            Divider()
                .frame(height: 24)

            Button(role: .destructive) {
                rows.removeAll()
                selectedRowId = nil
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .buttonStyle(.bordered)

            Spacer()

            // Status
            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(AppColors.error)
                    Text(error)
                        .foregroundColor(AppColors.error)
                }
                .font(.system(size: 13))
            }

            // Valid count badge
            let validCount = rows.filter { $0.isValid }.count
            HStack(spacing: 4) {
                Circle()
                    .fill(validCount == rows.count ? AppColors.success : AppColors.warning)
                    .frame(width: 8, height: 8)
                Text("\(validCount)/\(rows.count) valid")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(16)
        .background(AppColors.surface)
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
        // Select first row by default
        selectedRowId = rows.first?.id
    }

    private func save() {
        let items = rows.compactMap { row -> MatchItem? in
            guard let url = URL(string: row.urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.hasPrefix("http") == true else {
                return nil
            }

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

    private func moveRow(at index: Int, direction: Int) {
        let newIndex = index + direction
        guard rows.indices.contains(newIndex) else { return }
        rows.swapAt(index, newIndex)
    }

    private func deleteRow(at index: Int) {
        let deletedId = rows[index].id
        rows.remove(at: index)
        if selectedRowId == deletedId {
            selectedRowId = rows.first?.id
        }
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
        selectedRowId = newRows.first?.id
        #endif
    }
}

// MARK: - Queue Match Row

struct QueueMatchRow: View {
    let index: Int
    @Binding var row: QueueRow
    let isSelected: Bool
    let onSelect: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    let isFirst: Bool
    let isLast: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Index number
            Text("\(index)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(AppColors.textMuted)
                .frame(width: 40)

            // Match info
            VStack(alignment: .leading, spacing: 4) {
                // Team names - prominent
                Text(row.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                // Match number badge
                HStack(spacing: 8) {
                    if !row.matchNumber.isEmpty {
                        Text("Match \(row.matchNumber)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColors.primary)
                    }

                    if !row.matchTypeLabel.isEmpty {
                        Text(row.matchTypeLabel)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(row.matchTypeLabel == "Pool" ? AppColors.info : AppColors.primary)
                            )
                    }

                    // Validity indicator
                    if !row.isValid && !row.urlString.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Invalid URL")
                        }
                        .font(.system(size: 10))
                        .foregroundColor(AppColors.error)
                    }
                }
            }
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            // Schedule - Day & Time (prominent, color-coded)
            HStack(spacing: 8) {
                if !row.startDate.isEmpty {
                    Text(row.startDate)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(dayColor(for: row.startDate))
                        )
                }

                if !row.scheduledTime.isEmpty {
                    Text(row.scheduledTime)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(AppColors.textPrimary)
                }
            }
            .frame(width: 120, alignment: .center)

            // Action buttons
            HStack(spacing: 4) {
                Button { onMoveUp() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.borderless)
                .disabled(isFirst)
                .foregroundColor(isFirst ? AppColors.textMuted : AppColors.textSecondary)

                Button { onMoveDown() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.borderless)
                .disabled(isLast)
                .foregroundColor(isLast ? AppColors.textMuted : AppColors.textSecondary)

                Button { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundColor(AppColors.error.opacity(0.8))
            }
            .frame(width: 100, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? AppColors.primary.opacity(0.1) : (isHovered ? AppColors.surfaceElevated : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? AppColors.primary.opacity(0.3) : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .padding(.horizontal, 8)
    }

    private func dayColor(for day: String) -> Color {
        switch day.lowercased().prefix(3) {
        case "sat": return AppColors.info
        case "sun": return AppColors.warning
        case "fri": return AppColors.success
        case "thu": return Color.purple
        default: return AppColors.textMuted
        }
    }
}

// MARK: - Match Detail Editor

struct MatchDetailEditor: View {
    @Binding var row: QueueRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Teams section
                GroupBox("Teams") {
                    VStack(spacing: 12) {
                        LabeledField(label: "Team 1", text: $row.team1)
                        LabeledField(label: "Team 1 Seed", text: $row.team1Seed)
                        Divider()
                        LabeledField(label: "Team 2", text: $row.team2)
                        LabeledField(label: "Team 2 Seed", text: $row.team2Seed)
                    }
                }

                // Schedule section
                GroupBox("Schedule") {
                    VStack(spacing: 12) {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Day")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textMuted)
                                Picker("", selection: $row.startDate) {
                                    Text("—").tag("")
                                    Text("Thursday").tag("Thu")
                                    Text("Friday").tag("Fri")
                                    Text("Saturday").tag("Sat")
                                    Text("Sunday").tag("Sun")
                                }
                                .pickerStyle(.menu)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Time")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textMuted)
                                TextField("e.g., 9:00AM", text: $row.scheduledTime)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        LabeledField(label: "Match Number", text: $row.matchNumber)
                        LabeledField(label: "Court Number", text: $row.courtNumber)
                    }
                }

                // Match type section
                GroupBox("Match Type") {
                    VStack(spacing: 12) {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Type")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textMuted)
                                Picker("", selection: $row.matchType) {
                                    Text("—").tag("")
                                    Text("Pool Play").tag("Pool Play")
                                    Text("Bracket Play").tag("Bracket Play")
                                }
                                .pickerStyle(.menu)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Detail")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textMuted)
                                TextField("e.g., Pool A, Winners", text: $row.typeDetail)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }

                // API URL section
                GroupBox("API URL") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("https://api.volleyballlife.com/...", text: $row.urlString)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        HStack {
                            Circle()
                                .fill(row.isValid ? AppColors.success : (row.urlString.isEmpty ? AppColors.textMuted : AppColors.error))
                                .frame(width: 8, height: 8)
                            Text(row.isValid ? "Valid URL" : (row.urlString.isEmpty ? "Enter URL" : "Invalid URL"))
                                .font(.system(size: 11))
                                .foregroundColor(row.isValid ? AppColors.success : AppColors.textMuted)
                        }
                    }
                }

                Spacer()
            }
            .padding(16)
        }
    }
}

// MARK: - Helper Views

struct LabeledField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(AppColors.textMuted)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
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
    var matchType: String = ""
    var typeDetail: String = ""
    var courtNumber: String = ""
    var physicalCourt: String = ""
    var setsToWin: Int? = nil
    var pointsPerSet: Int? = nil
    var pointCap: Int? = nil
    var formatText: String = ""

    private func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func abbreviateName(_ name: String) -> String {
        let players = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }

        let abbreviated = players.map { player -> String in
            let cleanedPlayer = cleanName(player)
            let parts = cleanedPlayer.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { return cleanedPlayer }

            let firstName = parts[0]
            let lastName = parts[parts.count - 1]
            return "\(firstName.prefix(1)). \(lastName)"
        }

        return abbreviated.joined(separator: " / ")
    }

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

        if !label.isEmpty {
            if let _ = Int(label.trimmingCharacters(in: .whitespaces)) {
                return "Match \(label)"
            }
            return label
        }

        return "New Match"
    }

    var matchTypeLabel: String {
        if matchType.lowercased().contains("pool") {
            return "Pool"
        } else if matchType.lowercased().contains("bracket") {
            return "Bracket"
        }

        let urlLower = urlString.lowercased()
        if urlLower.contains("pool") || urlLower.contains("/pools/") {
            return "Pool"
        } else if urlLower.contains("bracket") {
            return "Bracket"
        }

        return ""
    }

    var isValid: Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.scheme?.hasPrefix("http") == true
    }
}

#Preview {
    QueueEditorView(courtId: 1)
        .environmentObject(AppViewModel())
}
