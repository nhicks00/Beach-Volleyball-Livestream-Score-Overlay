//
//  ChangeLogView.swift
//  MultiCourtScore
//
//  View to display metadata changes
//

import SwiftUI

struct ChangeLogView: View {
    @StateObject private var changeLog = ChangeLogService.shared
    @EnvironmentObject var appViewModel: AppViewModel
    
    @State private var searchText = ""
    @State private var filterCourt: Int? = nil
    
    var filteredLogs: [ChangeLogItem] {
        changeLog.logs.filter { item in
            let matchesCourt = filterCourt == nil || item.courtId == filterCourt
            let matchesSearch = searchText.isEmpty || 
                item.matchLabel.localizedCaseInsensitiveContains(searchText) ||
                item.teamVsTeam.localizedCaseInsensitiveContains(searchText) ||
                item.fieldName.localizedCaseInsensitiveContains(searchText) ||
                item.oldValue.localizedCaseInsensitiveContains(searchText) ||
                item.newValue.localizedCaseInsensitiveContains(searchText)
            
            return matchesCourt && matchesSearch
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header / Filter Bar
            HStack(spacing: 12) {
                // Court Filter
                Menu {
                    Button("All Courts") { filterCourt = nil }
                    ForEach(appViewModel.courts) { court in
                        Button("Court \(court.id)") { filterCourt = court.id }
                    }
                } label: {
                    Label(filterCourt == nil ? "All Courts" : "Court \(filterCourt!)", systemImage: "video")
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderedButton)
                .frame(width: 120)
                
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(AppColors.textMuted)
                    TextField("Search changes...", text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(AppColors.textPrimary)
                }
                .padding(8)
                .background(AppColors.surface)
                .cornerRadius(6)
                
                Spacer()
                
                // Clear Button
                Button {
                    changeLog.clearLogs()
                } label: {
                    Label("Clear Log", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(AppColors.textMuted)
            }
            .padding()
            .background(AppColors.surface)
            .overlay(Rectangle().frame(height: 1).foregroundColor(AppColors.border), alignment: .bottom)
            
            // List
            if filteredLogs.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundColor(AppColors.textMuted.opacity(0.3))
                    Text("No changes detected yet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppColors.textMuted)
                    Text("Metadata updates will appear here automatically")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredLogs) { item in
                        ChangeLogItemView(item: item)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .padding(.top, 8)
            }
        }
        .background(AppColors.background)
    }
}

struct ChangeLogItemView: View {
    let item: ChangeLogItem
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Time
            Text(item.displayTime)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(AppColors.textMuted)
                .frame(width: 70, alignment: .leading)
                .padding(.top, 2)
            
            // Court Badge
            Text("CT\(item.courtId)")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AppColors.primary.opacity(0.2))
                .foregroundColor(AppColors.primary)
                .cornerRadius(4)
                .padding(.top, 1)
            
            VStack(alignment: .leading, spacing: 4) {
                // Header: Match & Details
                HStack {
                    Text(item.matchLabel)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                    
                    Text("•")
                        .foregroundColor(AppColors.textMuted)
                    
                    Text(item.teamVsTeam)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(1)
                }
                
                // Change Details
                HStack(alignment: .firstTextBaseline) {
                    Text(item.fieldName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColors.info)
                        .frame(width: 80, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(item.oldValue.isEmpty ? "(empty)" : item.oldValue)
                                .strikethrough()
                                .foregroundColor(AppColors.error.opacity(0.8))
                            
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundColor(AppColors.textMuted)
                            
                            Text(item.newValue.isEmpty ? "(empty)" : item.newValue)
                                .bold()
                                .foregroundColor(AppColors.success)
                        }
                    }
                }
                .font(.system(size: 12))
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppColors.surface)
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
