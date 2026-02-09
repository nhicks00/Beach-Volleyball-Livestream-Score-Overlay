//
//  CourtMapping.swift
//  MultiCourtScore v2
//
//  Maps VBL court names to camera IDs for automatic queue assignment
//

import Foundation

// MARK: - Court Mapping

/// Maps a VBL court name (e.g., "Court 1", "Stadium Court") to a camera ID
struct CourtMapping: Codable, Identifiable, Hashable {
    var id = UUID()
    var courtNames: [String]  // Multiple names can map to same camera (e.g., "Court 1", "Ct 1")
    var cameraId: Int         // 1 = Core 1, 2 = Mevo 2, etc.
    
    /// Check if this mapping includes a given court name (case-insensitive)
    func matches(courtName: String) -> Bool {
        let normalized = courtName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return courtNames.contains { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalized }
    }
}

// MARK: - Court Mapping Store

/// Persisted store for current tournament's court-to-camera mappings
@MainActor
class CourtMappingStore: ObservableObject {
    static let shared = CourtMappingStore()
    
    @Published var mappings: [CourtMapping] = []
    @Published var unmappedCourts: [String] = []  // Courts found but not yet mapped
    
    private let storageKey = "courtMappings"
    
    private func normalizedCourtName(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    init() {
        loadMappings()
    }
    
    // MARK: - Query Methods
    
    /// Get camera ID for a court name, returns nil if not mapped
    func cameraId(for courtName: String) -> Int? {
        let normalized = normalizedCourtName(courtName)
        return mappings.first { mapping in
            mapping.courtNames.contains { normalizedCourtName($0) == normalized }
        }?.cameraId
    }
    
    /// Get all court names mapped to a specific camera
    func courtNames(for cameraId: Int) -> [String] {
        return mappings.filter { $0.cameraId == cameraId }.flatMap { $0.courtNames }
    }
    
    /// Check if a court name is mapped
    func isMapped(_ courtName: String) -> Bool {
        return cameraId(for: courtName) != nil
    }
    
    // MARK: - Mutation Methods
    
    /// Add or update a mapping for court names to a camera
    func setMapping(courtNames: [String], to cameraId: Int) {
        let cleanedNames = courtNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !cleanedNames.isEmpty else { return }
        
        // Remove these court names from any existing mappings
        for courtName in cleanedNames {
            removeCourtName(courtName, shouldSave: false)
        }
        
        // Check if camera already has a mapping
        if let existingIndex = mappings.firstIndex(where: { $0.cameraId == cameraId }) {
            // Add to existing mapping without duplicates.
            for courtName in cleanedNames where !mappings[existingIndex].courtNames.contains(where: { normalizedCourtName($0) == normalizedCourtName(courtName) }) {
                mappings[existingIndex].courtNames.append(courtName)
            }
        } else {
            // Create new mapping
            mappings.append(CourtMapping(courtNames: cleanedNames, cameraId: cameraId))
        }
        
        // Remove from unmapped list
        let normalizedIncoming = Set(cleanedNames.map(normalizedCourtName))
        unmappedCourts.removeAll { normalizedIncoming.contains(normalizedCourtName($0)) }
        
        saveMappings()
    }
    
    /// Remove a specific court name from all mappings
    func removeCourtName(_ courtName: String) {
        removeCourtName(courtName, shouldSave: true)
    }
    
    private func removeCourtName(_ courtName: String, shouldSave: Bool) {
        let normalized = normalizedCourtName(courtName)
        for i in mappings.indices {
            mappings[i].courtNames.removeAll { 
                normalizedCourtName($0) == normalized
            }
        }
        // Clean up empty mappings
        mappings.removeAll { $0.courtNames.isEmpty }
        if shouldSave {
            saveMappings()
        }
    }
    
    /// Clear all mappings (for new tournament)
    func clearAllMappings() {
        mappings.removeAll()
        unmappedCourts.removeAll()
        saveMappings()
    }
    
    /// Update unmapped courts list from scan results
    func updateUnmappedCourts(from allCourts: [String]) {
        unmappedCourts = allCourts.filter { !isMapped($0) }
    }
    
    // MARK: - Auto-Mapping
    
    /// Attempt to auto-map courts based on numbering patterns
    /// e.g., "Court 1" → Mevo 2, "Court 2" → Mevo 3
    func autoMap(courts: [String]) {
        let priorityPatterns = ["stadium", "center", "main", "feature", "show"]
        var priorityCourts: [String] = []
        var numberedCourts: [(name: String, number: Int)] = []
        var otherCourts: [String] = []
        
        for courtName in courts {
            let lower = courtName.lowercased()
            
            if priorityPatterns.contains(where: { lower.contains($0) }) {
                priorityCourts.append(courtName)
            } else if let num = extractCourtNumber(from: courtName) {
                numberedCourts.append((name: courtName, number: num))
            } else {
                otherCourts.append(courtName)
            }
        }
        
        // Sort numbered courts
        numberedCourts.sort { $0.number < $1.number }
        
        // Priority courts → Core 1
        if !priorityCourts.isEmpty {
            setMapping(courtNames: priorityCourts, to: 1)
        }
        
        // Numbered courts → Mevo 2, 3, 4...
        for (index, court) in numberedCourts.enumerated() {
            let cameraId = min(index + 2, 10)  // Mevo 2-10
            setMapping(courtNames: [court.name], to: cameraId)
        }
        
        // Remaining courts → next available
        let nextStart = numberedCourts.count + 2
        for (index, courtName) in otherCourts.enumerated() {
            let cameraId = min(nextStart + index, 10)
            setMapping(courtNames: [courtName], to: cameraId)
        }
    }
    
    private func extractCourtNumber(from name: String) -> Int? {
        let digits = name.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
    
    // MARK: - Persistence
    
    private func saveMappings() {
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func loadMappings() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([CourtMapping].self, from: data) {
            mappings = decoded
        }
    }
}

// MARK: - Match Reassignment Event

/// Represents a court change event for notification purposes
struct CourtChangeEvent: Identifiable {
    let id = UUID()
    let matchLabel: String
    let oldCourt: String
    let newCourt: String
    let oldCamera: Int
    let newCamera: Int
    let isLiveMatch: Bool
    let timestamp: Date
    
    var urgency: NotificationUrgency {
        isLiveMatch ? .critical : .warning
    }
    
    var description: String {
        let cameraChange = "\(CourtNaming.displayName(for: oldCamera)) → \(CourtNaming.displayName(for: newCamera))"
        return "\(matchLabel) moved from \(oldCourt) to \(newCourt) (\(cameraChange))"
    }
}

enum NotificationUrgency {
    case critical  // Live match affected
    case warning   // Queued match moved
    case info      // General update
}
