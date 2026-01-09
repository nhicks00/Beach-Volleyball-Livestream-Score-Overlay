import SwiftUI
#if os(macOS)
import AppKit
#endif

struct QueueEditorView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let courtId: Int
    var onSave: ([MatchItem]) -> Void

    @State private var rows: [Row] = []
    @State private var error: String?

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var label: String = ""
        var urlString: String = ""
        var isValid: Bool { URL(string: urlString)?.scheme?.hasPrefix("http") == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Queue — \(courtTitle)").font(.title3.weight(.semibold))
            
            HStack {
                Text("Match Label").font(.caption).foregroundStyle(.secondary)
                Spacer().frame(minWidth: 100)
                Text("API URL").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 8)

            List {
                ForEach($rows) { $row in
                    RowEditor(row: $row,
                              moveUp: { moveRow(row, direction: -1) },
                              moveDown: { moveRow(row, direction: 1) },
                              remove: { rows.removeAll { $0.id == row.id } },
                              isFirst: rows.first?.id == row.id,
                              isLast: rows.last?.id == row.id)
                }
            }
            .frame(minHeight: 220, maxHeight: 400)
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack(spacing: 10) {
                Button { rows.append(Row()) } label: { Label("Add Row", systemImage: "plus.circle.fill") }
                Button { pasteRows() } label: { Label("Paste Rows", systemImage: "doc.on.clipboard") }
                Spacer()
                if let err = error { Text(err).foregroundStyle(.red).font(.footnote) }
                Button("Save", action: save).buttonStyle(.borderedProminent)
                Button("Cancel", role: .cancel) { dismiss() }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(minWidth: 780)
        .onAppear(perform: loadQueue)
    }

    private struct RowEditor: View {
        @Binding var row: Row
        var moveUp, moveDown, remove: () -> Void
        var isFirst, isLast: Bool

        var body: some View {
            HStack(spacing: 12) {
                TextField("Round of 16, Pool A, …", text: $row.label)
                TextField("https://api.volleyballlife.com/…", text: $row.urlString)
                    .font(.footnote.monospaced())
                Circle().fill(row.isValid ? Color.green : Color.red).frame(width: 8, height: 8)
                HStack(spacing: 6) {
                    Button(action: moveUp) { Image(systemName: "chevron.up") }.disabled(isFirst)
                    Button(action: moveDown) { Image(systemName: "chevron.down") }.disabled(isLast)
                    Button(role: .destructive, action: remove) { Image(systemName: "minus.circle.fill") }
                }.buttonStyle(.borderless)
            }
        }
    }

    private func loadQueue() {
        rows = (vm.courts.first { $0.id == courtId }?.queue ?? []).map {
            Row(label: $0.label ?? "", urlString: $0.apiURL.absoluteString)
        }
    }

    private func pasteRows() {
        #if os(macOS)
        guard let clip = NSPasteboard.general.string(forType: .string) else { return }
        let newRows = clip.split(separator: "\n", omittingEmptySubsequences: true).map { line -> Row in
            let pieces = line.split(separator: "|", maxSplits: 1).map(String.init)
            return Row(label: pieces.first?.trimmingCharacters(in: .whitespaces) ?? "",
                       urlString: (pieces.count > 1 ? pieces[1] : String(line)).trimmingCharacters(in: .whitespaces))
        }
        rows.append(contentsOf: newRows)
        #endif
    }

    private func save() {
        let items = rows.compactMap { r -> MatchItem? in
            guard let url = URL(string: r.urlString), url.scheme?.hasPrefix("http") == true else { return nil }
            return MatchItem(apiURL: url, label: r.label.isEmpty ? nil : r.label)
        }
        
        if items.count != rows.count {
            error = "One or more URLs are invalid."
            return
        }
        
        error = nil
        onSave(items)
        dismiss()
    }
    
    private func moveRow(_ row: Row, direction: Int) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let newIndex = index + direction
        guard rows.indices.contains(newIndex) else { return }
        rows.swapAt(index, newIndex)
    }

    private var courtTitle: String {
        vm.courts.first { $0.id == courtId }?.name ?? "Unknown Court"
    }
}
