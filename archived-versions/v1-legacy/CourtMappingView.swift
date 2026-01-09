import SwiftUI

struct CourtMappingView: View {
    let selectedCourts: [String]
    let availableLocalCourts: [Court]
    @Binding var courtMapping: [String: Int]
    let onComplete: () -> Void
    
    private var sortedSelectedCourts: [String] {
        selectedCourts.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Map Courts to Cameras").font(.title2.bold())
            Text("Map each tournament court to your local camera setup:").foregroundColor(.secondary)
            
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(sortedSelectedCourts, id: \.self) { court in
                        HStack {
                            Text("Court \(court)").frame(width: 80, alignment: .leading).fontWeight(.semibold)
                            Image(systemName: "arrow.right").foregroundColor(.secondary)
                            Picker("Camera", selection: Binding(
                                get: { courtMapping[court] ?? -1 },
                                set: { courtMapping[court] = $0 == -1 ? nil : $0 }
                            )) {
                                Text("Select Camera").tag(-1)
                                ForEach(availableLocalCourts, id: \.id) { localCourt in
                                    Text(localCourt.name).tag(localCourt.id)
                                }
                            }
                            .frame(width: 200)
                            Spacer()
                        }
                    }
                }
                .padding()
                .background(.regularMaterial)
                .cornerRadius(12)
            }
            
            HStack {
                Button("Auto-Map", action: autoMapCourts).buttonStyle(.bordered)
                Spacer()
                Button("Complete Import", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .disabled(hasMissingMappings())
            }
        }
        .padding(20)
    }
    
    private func autoMapCourts() {
        let sortedCameras = availableLocalCourts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        for (index, court) in sortedSelectedCourts.enumerated() {
            if index < sortedCameras.count {
                courtMapping[court] = sortedCameras[index].id
            }
        }
    }
    
    private func hasMissingMappings() -> Bool {
        selectedCourts.contains { courtMapping[$0] == nil }
    }
}
