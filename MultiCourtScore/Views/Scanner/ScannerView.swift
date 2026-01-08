//
//  ScannerView.swift
//  MultiCourtScore v2
//
//  VBL bracket/pool scanning interface
//

import SwiftUI

struct ScannerView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    // Use the shared scannerViewModel from appViewModel so results persist
    private var viewModel: ScannerViewModel { appViewModel.scannerViewModel }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            ScannerHeader(
                onDone: { dismiss() },
                onClear: { viewModel.clearResults() }
            )
            
            ScrollView {
                VStack(spacing: AppLayout.sectionPadding) {
                    // URL Input Section
                    URLInputSection(viewModel: viewModel)
                    
                    // Scan Button
                    ScanButtonSection(viewModel: viewModel)
                    
                    // Progress/Logs Section
                    if viewModel.isScanning || !viewModel.scanLogs.isEmpty {
                        ScanProgressSection(viewModel: viewModel)
                    }
                    
                    // Error Display
                    if let error = viewModel.errorMessage {
                        ErrorBanner(message: error)
                    }
                    
                    // Results Section
                    if !viewModel.scanResults.isEmpty {
                        ScanResultsSection(viewModel: viewModel)
                    }
                }
                .padding(AppLayout.contentPadding)
            }
        }
        .frame(minWidth: 700, minHeight: 600)
        .background(AppColors.background)
    }
}

// MARK: - Header
struct ScannerHeader: View {
    let onDone: () -> Void
    let onClear: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan VolleyballLife")
                    .font(AppTypography.title)
                    .foregroundColor(AppColors.textPrimary)
                
                Text("Enter bracket and pool URLs to extract match data")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
            
            Spacer()
            
            Button("Clear") { onClear() }
                .buttonStyle(.bordered)
            
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
        }
        .padding(AppLayout.contentPadding)
        .background(AppColors.surface)
    }
}

// MARK: - URL Input Section
struct URLInputSection: View {
    @ObservedObject var viewModel: ScannerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.itemSpacing) {
            // Bracket URLs
            HStack {
                SectionHeader(title: "Bracket URLs", subtitle: "\(viewModel.bracketURLs.filter { !$0.isEmpty }.count) entered")
                Spacer()
                Button {
                    viewModel.addBracketURL()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(AppColors.primary)
                }
                .buttonStyle(.plain)
            }
            
            ForEach(viewModel.bracketURLs.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    URLInputRow(
                        placeholder: "Enter bracket URL \(index + 1)...",
                        text: $viewModel.bracketURLs[index],
                        isOptional: index > 0
                    )
                    
                    if viewModel.bracketURLs.count > 1 {
                        Button {
                            viewModel.removeBracketURL(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(AppColors.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            Divider()
                .background(AppColors.textMuted.opacity(0.3))
                .padding(.vertical, 8)
            
            // Pool URLs
            HStack {
                SectionHeader(title: "Pool URLs", subtitle: "\(viewModel.poolURLs.filter { !$0.isEmpty }.count) entered")
                Spacer()
                Button {
                    viewModel.addPoolURL()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(AppColors.primary)
                }
                .buttonStyle(.plain)
            }
            
            ForEach(viewModel.poolURLs.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    URLInputRow(
                        placeholder: "Enter pool URL \(index + 1)...",
                        text: $viewModel.poolURLs[index],
                        isOptional: true
                    )
                    
                    if viewModel.poolURLs.count > 1 {
                        Button {
                            viewModel.removePoolURL(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(AppColors.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surface)
        )
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)
            
            Spacer()
            
            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textMuted)
        }
    }
}

struct URLInputRow: View {
    let placeholder: String
    @Binding var text: String
    let isOptional: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(AppColors.textPrimary)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                        .fill(AppColors.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                        .stroke(text.isEmpty ? AppColors.textMuted.opacity(0.2) : AppColors.primary.opacity(0.5), lineWidth: 1)
                )
            
            if text.isEmpty && isOptional {
                Text("Optional")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
                    .frame(width: 60)
            } else if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.error)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Scan Button Section
struct ScanButtonSection: View {
    @ObservedObject var viewModel: ScannerViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("URLs to scan: \(viewModel.allURLs.count)")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
                Spacer()
            }
            
            if viewModel.isScanning {
                Button {
                    viewModel.cancelScan()
                } label: {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                        Text("Cancel Scan")
                    }
                    .font(AppTypography.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: AppLayout.buttonCornerRadius)
                            .fill(AppColors.error)
                    )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    viewModel.startScan()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass.circle.fill")
                        Text("Scan \(viewModel.allURLs.count) URL\(viewModel.allURLs.count == 1 ? "" : "s")")
                    }
                    .font(AppTypography.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: AppLayout.buttonCornerRadius)
                            .fill(viewModel.canScan ? AppColors.primary : AppColors.textMuted)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canScan)
            }
        }
    }
}

// MARK: - Progress Section
struct ScanProgressSection: View {
    @ObservedObject var viewModel: ScannerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.itemSpacing) {
            HStack {
                Text("Scan Progress")
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                
                Spacer()
                
                Text("\(viewModel.scanLogs.count) entries")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }
            
            if viewModel.isScanning {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    
                    Text(viewModel.scanProgress)
                        .font(AppTypography.body)
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.vertical, 8)
            }
            
            // Log entries
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.scanLogs.suffix(30)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.type.icon)
                                .font(.system(size: 11))
                            
                            Text(entry.timeDisplay)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(AppColors.textMuted)
                                .frame(width: 55, alignment: .leading)
                            
                            Text(entry.message)
                                .font(AppTypography.caption)
                                .foregroundColor(entry.type.color)
                        }
                    }
                }
            }
            .frame(height: 150)
            .padding(AppLayout.itemSpacing)
            .background(
                RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                    .fill(AppColors.surfaceElevated)
            )
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surface)
        )
    }
}

// MARK: - Error Banner
struct ErrorBanner: View {
    let message: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppColors.error)
            
            Text(message)
                .font(AppTypography.body)
                .foregroundColor(AppColors.error)
            
            Spacer()
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.errorBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                        .stroke(AppColors.error.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Results Section
struct ScanResultsSection: View {
    @ObservedObject var viewModel: ScannerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.itemSpacing) {
            HStack {
                Text("Found \(viewModel.scanResults.count) matches")
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                
                Spacer()
                
                Text("Grouped by court")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }
            
            ForEach(viewModel.groupedByCourt.keys.sorted(), id: \.self) { courtName in
                if let matches = viewModel.groupedByCourt[courtName] {
                    CourtResultGroup(courtName: courtName, matches: matches)
                }
            }
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surface)
        )
    }
}

struct CourtResultGroup: View {
    let courtName: String
    let matches: [ScannerViewModel.VBLMatch]
    
    @State private var isExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppColors.textMuted)
                    
                    Text("Court \(courtName)")
                        .font(AppTypography.callout)
                        .foregroundColor(AppColors.textPrimary)
                    
                    Text("\(matches.count) matches")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(AppColors.surfaceHover)
                        )
                    
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                ForEach(matches) { match in
                    HStack {
                        Text(match.displayName)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                        
                        Spacer()
                        
                        if match.startTime != nil || match.startDate != nil {
                            Text(match.dateTimeDisplay)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(AppColors.textMuted)
                        }
                        
                        Image(systemName: match.hasAPIURL ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.system(size: 12))
                            .foregroundColor(match.hasAPIURL ? AppColors.success : AppColors.error)
                    }
                    .padding(.leading, 20)
                }
            }
        }
        .padding(AppLayout.itemSpacing)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                .fill(AppColors.surfaceElevated)
        )
    }
}

#Preview {
    ScannerView()
        .environmentObject(AppViewModel())
}
