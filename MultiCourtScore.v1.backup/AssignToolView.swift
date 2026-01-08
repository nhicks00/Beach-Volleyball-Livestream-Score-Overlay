import SwiftUI

struct AssignToolView: View {
    @ObservedObject var vblBridge: VBLPythonBridge
    @ObservedObject var vm: AppViewModel
    let onClose: () -> Void
    
    @State private var groupedByCourt: [String: [VBLPythonBridge.VBLMatchData]] = [:]
    @State private var matchAssignments: [UUID: Int] = [:]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Text("Assign Matches to Court Overlays")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            
            if vblBridge.lastScanResults.isEmpty {
                // No scan data available
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No scan data available")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Run a VBL scan first to get match data for assignment")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Found \(vblBridge.lastScanResults.count) matches from VolleyballLife bracket. Assign them to your court overlays (1-10).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(groupedByCourt.keys.sorted(), id: \.self) { court in
                            CourtGroupSection(
                                courtName: court,
                                matches: groupedByCourt[court] ?? [],
                                matchAssignments: $matchAssignments,
                                vm: vm
                            )
                        }
                    }
                    .padding(.horizontal)
                }
                
                HStack {
                    Button("Auto Assign") {
                        autoAssignMatches()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button("Import to Courts") {
                        importAssignedMatches()
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(matchAssignments.values.contains(0))
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .onAppear {
            loadMatches()
        }
    }
    
    private func loadMatches() {
        var groups: [String: [VBLPythonBridge.VBLMatchData]] = [:]
        
        for match in vblBridge.lastScanResults {
            let court = match.courtDisplay
            if groups[court] == nil {
                groups[court] = []
            }
            groups[court]?.append(match)
        }
        
        groupedByCourt = groups
        
        // Initialize assignments
        for match in vblBridge.lastScanResults {
            matchAssignments[match.id] = 0 // 0 means unassigned
        }
    }
    
    private func autoAssignMatches() {
        var courtIndex = 1
        for match in vblBridge.lastScanResults {
            matchAssignments[match.id] = courtIndex
            courtIndex += 1
            if courtIndex > 10 {
                courtIndex = 1 // Wrap around
            }
        }
    }
    
    private func importAssignedMatches() {
        // Group matches by assigned court
        var matchesByCourtId: [Int: [VBLPythonBridge.VBLMatchData]] = [:]
        
        for match in vblBridge.lastScanResults {
            guard let assignedCourtId = matchAssignments[match.id],
                  assignedCourtId > 0 else {
                continue
            }
            
            if matchesByCourtId[assignedCourtId] == nil {
                matchesByCourtId[assignedCourtId] = []
            }
            matchesByCourtId[assignedCourtId]?.append(match)
        }
        
        // Import matches to each court using the existing populateCourtFromVBL method
        for (courtId, matches) in matchesByCourtId {
            vm.populateCourtFromVBL(courtId: courtId, matches: matches)
        }
    }
    
    private func createMatchItem(from match: VBLPythonBridge.VBLMatchData) -> MatchItem? {
        guard let apiURLString = match.apiURL,
              let apiURL = URL(string: apiURLString) else {
            return nil
        }
        
        return MatchItem(
            apiURL: apiURL,
            label: match.displayName,
            team1Name: match.team1,
            team2Name: match.team2
        )
    }
}

struct CourtGroupSection: View {
    let courtName: String
    let matches: [VBLPythonBridge.VBLMatchData]
    @Binding var matchAssignments: [UUID: Int]
    let vm: AppViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Court \(courtName)")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("\(matches.count) matches")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
                
                Spacer()
                
                Menu("Assign All to Overlay ?") {
                    ForEach(1...10, id: \.self) { overlayId in
                        Button(getCourtDisplayName(overlayId)) {
                            for match in matches {
                                matchAssignments[match.id] = overlayId
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(matches, id: \.id) { match in
                    MatchAssignmentCard(
                        match: match,
                        assignedOverlay: Binding(
                            get: { matchAssignments[match.id] ?? 0 },
                            set: { matchAssignments[match.id] = $0 }
                        )
                    )
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
    
    private func getCourtDisplayName(_ courtId: Int) -> String {
        if courtId == 1 {
            return "Core 1"
        } else {
            return "Mevo \(courtId - 1)"
        }
    }
}

struct MatchAssignmentCard: View {
    let match: VBLPythonBridge.VBLMatchData
    @Binding var assignedOverlay: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(match.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            
            // Match Type and Detail
            if let matchType = match.matchType {
                HStack(spacing: 4) {
                    Text(matchType)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(matchType.contains("Pool") ? Color.blue : Color.purple)
                        .cornerRadius(4)
                    
                    if let typeDetail = match.typeDetail, !typeDetail.isEmpty {
                        Text(typeDetail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            HStack {
                Text("Time: \(match.timeDisplay)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if match.apiURL != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            
            Menu("Overlay \(assignedOverlay == 0 ? "?" : getOverlayName(assignedOverlay))") {
                Button("Unassigned") { assignedOverlay = 0 }
                ForEach(1...10, id: \.self) { overlayId in
                    Button(getOverlayName(overlayId)) {
                        assignedOverlay = overlayId
                    }
                }
            }
            .buttonStyle(.bordered)
            .foregroundColor(assignedOverlay == 0 ? .secondary : .primary)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(assignedOverlay > 0 ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func getOverlayName(_ overlayId: Int) -> String {
        if overlayId == 1 {
            return "Core 1"
        } else {
            return "Mevo \(overlayId - 1)"
        }
    }
}