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
                team2: match.team2Name ?? ""
            )
        }
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
                team2Name: row.team2.isEmpty ? nil : row.team2
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
            // Label
            TextField("Round, Pool A...", text: $row.label)
                .textFieldStyle(.plain)
                .frame(width: 120)
                .padding(8)
                .background(AppColors.surface)
                .cornerRadius(AppLayout.smallCornerRadius)
            
            // URL
            TextField("https://api.volleyballlife.com/...", text: $row.urlString)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(AppColors.surface)
                .cornerRadius(AppLayout.smallCornerRadius)
            
            // Validity indicator
            Circle()
                .fill(row.isValid ? AppColors.success : (row.urlString.isEmpty ? AppColors.textMuted : AppColors.error))
                .frame(width: 10, height: 10)
            
            // Move buttons
            HStack(spacing: 4) {
                Button { onMoveUp() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(isFirst)
                
                Button { onMoveDown() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(isLast)
                
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(AppColors.error)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
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
