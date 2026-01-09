//
//  ControlBar.swift
//  MultiCourtScore v2
//
//  Top action button bar for global controls
//

import SwiftUI

struct ControlBar: View {
    let onStartAll: () -> Void
    let onStopAll: () -> Void
    let onClearAll: () -> Void
    let onScanVBL: () -> Void
    let onAssignTool: () -> Void
    
    var body: some View {
        HStack(spacing: AppLayout.itemSpacing) {
            // Start All
            ControlButton(
                title: "Start All",
                icon: "play.circle.fill",
                color: AppColors.success,
                action: onStartAll
            )
            
            // Stop All
            ControlButton(
                title: "Stop All",
                icon: "stop.circle.fill",
                color: AppColors.error,
                action: onStopAll
            )
            
            // Clear All
            ControlButton(
                title: "Clear All",
                icon: "trash.circle.fill",
                color: AppColors.warning,
                action: onClearAll
            )
            
            Spacer()
            
            // Scan VBL
            ControlButton(
                title: "Scan VBL",
                icon: "magnifyingglass.circle.fill",
                color: AppColors.primary,
                action: onScanVBL
            )
            
            // Assign Tool
            ControlButton(
                title: "Assign",
                icon: "arrow.down.to.line.compact",
                color: AppColors.info,
                action: onAssignTool
            )
        }
    }
}

// MARK: - Control Button Component
struct ControlButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(AppTypography.callout)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppLayout.buttonCornerRadius)
                    .fill(isHovered ? color.opacity(0.85) : color)
            )
            .shadow(color: color.opacity(0.3), radius: isHovered ? 8 : 4, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Status Summary Bar
struct StatusSummaryBar: View {
    let courts: [Court]
    
    private var liveCount: Int { courts.filter { $0.status == .live }.count }
    private var waitingCount: Int { courts.filter { $0.status == .waiting }.count }
    private var totalMatches: Int { courts.reduce(0) { $0 + $1.queue.count } }
    
    var body: some View {
        HStack(spacing: 24) {
            StatusPill(
                label: "Live",
                count: liveCount,
                color: AppColors.success
            )
            
            StatusPill(
                label: "Waiting", 
                count: waitingCount,
                color: AppColors.warning
            )
            
            StatusPill(
                label: "Total Matches",
                count: totalMatches,
                color: AppColors.info
            )
            
            Spacer()
        }
        .padding(.horizontal, AppLayout.contentPadding)
        .padding(.vertical, AppLayout.smallSpacing)
        .background(AppColors.surfaceElevated)
    }
}

struct StatusPill: View {
    let label: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(AppColors.textPrimary)
            
            Text(label)
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
    }
}

#Preview {
    VStack {
        ControlBar(
            onStartAll: {},
            onStopAll: {},
            onClearAll: {},
            onScanVBL: {},
            onAssignTool: {}
        )
        
        StatusSummaryBar(courts: [])
    }
    .padding()
    .background(AppColors.background)
}
