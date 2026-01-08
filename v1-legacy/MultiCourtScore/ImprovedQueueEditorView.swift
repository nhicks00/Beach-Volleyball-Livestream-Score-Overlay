import SwiftUI

struct ImprovedQueueEditorView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    let initialCourtId: Int
    
    @State private var courts: [CourtData] = []
    @State private var selectedMatch: MatchDisplayItem?
    @State private var showingMoveOptions = false
    
    struct CourtData: Identifiable {
        let id: Int
        let name: String
        var matches: [MatchDisplayItem]
    }
    
    struct MatchDisplayItem: Identifiable, Equatable {
        let id = UUID()
        let originalItem: MatchItem
        let displayName: String
        let subtitle: String
        var courtId: Int
        
        init(from item: MatchItem, courtId: Int) {
            self.originalItem = item
            self.courtId = courtId
            
            // Create a better display name from the match
            if let label = item.label, !label.isEmpty {
                self.displayName = label
                self.subtitle = "API Match"
            } else if let team1 = item.team1Name, let team2 = item.team2Name {
                self.displayName = "\(team1) vs \(team2)"
                self.subtitle = "Live Match"
            } else {
                self.displayName = "Match"
                self.subtitle = "API URL: \(item.apiURL.absoluteString)"
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Queue Manager")
                        .font(.title2.weight(.semibold))
                    Text("Drag matches between courts or use the move button")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    saveChanges()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            
            // Courts Grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 20) {
                    ForEach($courts) { $court in
                        CourtQueueCard(
                            court: $court,
                            selectedMatch: $selectedMatch,
                            onMoveMatch: { match in
                                selectedMatch = match
                                showingMoveOptions = true
                            },
                            onReorderMatches: { fromIndex, toIndex in
                                reorderMatches(in: court.id, from: fromIndex, to: toIndex)
                            }
                        )
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 600)
        .confirmationDialog(
            "Move \(selectedMatch?.displayName ?? "Match")",
            isPresented: $showingMoveOptions,
            presenting: selectedMatch
        ) { match in
            ForEach(courts.filter { $0.id != match.courtId }) { court in
                Button("Move to \(court.name)") {
                    moveMatch(match, to: court.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { match in
            Text("Choose which court to move this match to:")
        }
        .onAppear {
            loadQueues()
        }
    }
    
    private func loadQueues() {
        courts = vm.courts.map { court in
            CourtData(
                id: court.id,
                name: court.name,
                matches: court.queue.map { MatchDisplayItem(from: $0, courtId: court.id) }
            )
        }
    }
    
    private func moveMatch(_ match: MatchDisplayItem, to targetCourtId: Int) {
        guard let sourceCourtIndex = courts.firstIndex(where: { $0.id == match.courtId }),
              let targetCourtIndex = courts.firstIndex(where: { $0.id == targetCourtId }),
              let matchIndex = courts[sourceCourtIndex].matches.firstIndex(where: { $0.id == match.id }) else {
            return
        }
        
        // Remove from source court
        var updatedMatch = courts[sourceCourtIndex].matches.remove(at: matchIndex)
        
        // Update court ID
        updatedMatch.courtId = targetCourtId
        
        // Add to target court
        courts[targetCourtIndex].matches.append(updatedMatch)
        
        selectedMatch = nil
    }
    
    private func reorderMatches(in courtId: Int, from sourceIndex: Int, to destinationIndex: Int) {
        guard let courtIndex = courts.firstIndex(where: { $0.id == courtId }) else { return }
        
        let match = courts[courtIndex].matches.remove(at: sourceIndex)
        courts[courtIndex].matches.insert(match, at: destinationIndex)
    }
    
    private func saveChanges() {
        for court in courts {
            let matchItems = court.matches.map { $0.originalItem }
            vm.replaceQueue(court.id, with: matchItems)
        }
    }
}

struct CourtQueueCard: View {
    @Binding var court: ImprovedQueueEditorView.CourtData
    @Binding var selectedMatch: ImprovedQueueEditorView.MatchDisplayItem?
    let onMoveMatch: (ImprovedQueueEditorView.MatchDisplayItem) -> Void
    let onReorderMatches: (Int, Int) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Court Header
            HStack {
                Text(court.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text("\(court.matches.count) matches")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
            }
            
            // Queue Area
            VStack(spacing: 8) {
                if court.matches.isEmpty {
                    // Empty State
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("No matches queued")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [5]))
                    )
                } else {
                    // Matches List
                    ForEach(Array(court.matches.enumerated()), id: \.element.id) { index, match in
                        MatchQueueItem(
                            match: match,
                            position: index + 1,
                            isSelected: selectedMatch?.id == match.id,
                            onSelect: { selectedMatch = match },
                            onMove: { onMoveMatch(match) },
                            onMoveUp: index > 0 ? {
                                onReorderMatches(index, index - 1)
                            } : nil,
                            onMoveDown: index < court.matches.count - 1 ? {
                                onReorderMatches(index, index + 1)
                            } : nil
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

struct MatchQueueItem: View {
    let match: ImprovedQueueEditorView.MatchDisplayItem
    let position: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onMove: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 12) {
            // Position Number
            Text("\(position)")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue)
                .cornerRadius(10)
            
            // Match Info
            VStack(alignment: .leading, spacing: 2) {
                Text(match.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                
                Text(match.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Action Buttons
            HStack(spacing: 4) {
                // Reorder buttons
                Button(action: { onMoveUp?() }) {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                }
                .disabled(onMoveUp == nil)
                .buttonStyle(.borderless)
                
                Button(action: { onMoveDown?() }) {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .disabled(onMoveDown == nil)
                .buttonStyle(.borderless)
                
                // Move to different court
                Button(action: onMove) {
                    Image(systemName: "arrow.uturn.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .opacity(0.7)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
        )
        .onTapGesture {
            onSelect()
        }
    }
}