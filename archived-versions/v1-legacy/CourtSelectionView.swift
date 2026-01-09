import SwiftUI

struct CourtSelectionView: View {
    let availableCourts: [String]
    @Binding var selectedCourts: Set<String>
    let onNext: () -> Void
    
    private var sortedCourts: [String] {
        availableCourts.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Courts to Stream").font(.title2.bold())
            Text("Found matches on \(availableCourts.count) courts. Select which courts to import:").foregroundColor(.secondary)
            
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(sortedCourts, id: \.self) { court in
                        CourtToggleCard(court: court, isSelected: selectedCourts.contains(court)) {
                            if selectedCourts.contains(court) {
                                selectedCourts.remove(court)
                            } else {
                                selectedCourts.insert(court)
                            }
                        }
                    }
                }
            }
            
            HStack {
                Button("Select All") { selectedCourts = Set(availableCourts) }.buttonStyle(.bordered)
                Button("Select None") { selectedCourts.removeAll() }.buttonStyle(.bordered)
                Spacer()
                Button("Next", action: onNext).buttonStyle(.borderedProminent).disabled(selectedCourts.isEmpty)
            }
        }
        .padding(20)
    }
}


struct CourtToggleCard: View {
    let court: String
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 8) {
                Text("Court \(court)")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? .green : .secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.green : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
