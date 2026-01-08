//
//  CourtCard.swift
//  MultiCourtScore v2
//
//  Individual court overlay card with modern design
//

import SwiftUI

struct CourtCard: View {
    let court: Court
    let onStart: () -> Void
    let onStop: () -> Void
    let onSkipNext: () -> Void
    let onSkipPrevious: () -> Void
    let onEditQueue: () -> Void
    let onRename: () -> Void
    let onCopyURL: () -> Void
    
    @State private var isHovered = false
    
    // Status-based styling
    private var statusColor: Color {
        switch court.status {
        case .idle: return AppColors.textMuted
        case .waiting: return AppColors.warning
        case .live: return AppColors.success
        case .finished: return AppColors.info
        case .error: return AppColors.error
        }
    }
    
    private var statusBackground: Color {
        switch court.status {
        case .idle: return AppColors.idleBackground
        case .waiting: return AppColors.waitingBackground
        case .live: return AppColors.liveBackground
        case .finished: return AppColors.finishedBackground
        case .error: return AppColors.errorBackground
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.itemSpacing) {
            // Header
            CardHeader(court: court, statusColor: statusColor)
            
            // Score Display (when active match)
            if let snapshot = court.lastSnapshot, court.currentMatch != nil {
                ScoreDisplay(snapshot: snapshot, elapsedTime: court.elapsedTimeString)
            } else if court.queue.isEmpty {
                EmptyQueuePlaceholder()
            } else {
                WaitingForMatchView(match: court.currentMatch)
            }
            
            // Queue Preview
            if !court.upcomingMatches.isEmpty {
                QueuePreview(matches: court.upcomingMatches, remaining: court.remainingMatchCount)
            }
            
            Spacer(minLength: 4)
            
            // Control Buttons
            CardControls(
                isPolling: court.status.isPolling,
                hasQueue: !court.queue.isEmpty,
                onStart: onStart,
                onStop: onStop,
                onSkipPrevious: onSkipPrevious,
                onSkipNext: onSkipNext,
                onEditQueue: onEditQueue,
                onCopyURL: onCopyURL
            )
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                .fill(statusBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                        .fill(AppColors.surface.opacity(0.7))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                .stroke(statusColor.opacity(isHovered ? 0.8 : 0.4), lineWidth: AppLayout.borderWidth)
        )
        .shadow(color: statusColor.opacity(court.status == .live ? 0.3 : 0.1), radius: court.status == .live ? 12 : 6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Rename...") { onRename() }
            Button("Edit Queue...") { onEditQueue() }
            Divider()
            Button("Copy OBS URL") { onCopyURL() }
            Divider()
            Button("Clear Queue", role: .destructive) { /* handled by parent */ }
        }
    }
}

// MARK: - Card Header
struct CardHeader: View {
    let court: Court
    let statusColor: Color
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(court.displayName)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                
                Text("\(court.queue.count) match\(court.queue.count == 1 ? "" : "es") queued")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
            
            Spacer()
            
            // Status Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(statusColor.opacity(0.5), lineWidth: 2)
                            .scaleEffect(court.status == .live ? 1.6 : 1)
                            .opacity(court.status == .live ? 0 : 1)
                    )
                    .animation(court.status == .live ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: court.status)
                
                Text(court.status.displayName.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(statusColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(statusColor.opacity(0.15))
            )
        }
    }
}

// MARK: - Score Display
struct ScoreDisplay: View {
    let snapshot: ScoreSnapshot
    let elapsedTime: String?
    
    var body: some View {
        VStack(spacing: AppLayout.smallSpacing) {
            // Team names and scores
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    TeamScoreRow(name: snapshot.team1Name, score: snapshot.team1Score, isServing: snapshot.serve == "home")
                    TeamScoreRow(name: snapshot.team2Name, score: snapshot.team2Score, isServing: snapshot.serve == "away")
                }
                
                Spacer()
            }
            
            // Set history
            if !snapshot.setHistory.isEmpty {
                HStack(spacing: 8) {
                    Text("Sets:")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textMuted)
                    
                    ForEach(snapshot.setHistory, id: \.setNumber) { set in
                        Text(set.displayString)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(AppColors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(AppColors.surfaceHover)
                            )
                    }
                    
                    Spacer()
                    
                    if let time = elapsedTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(time)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(AppColors.textMuted)
                    }
                }
            }
            
            // Match status
            HStack {
                Text("Set \(snapshot.setNumber)")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
                
                Text("•")
                    .foregroundColor(AppColors.textMuted)
                
                Text(snapshot.status)
                    .font(AppTypography.caption)
                    .foregroundColor(snapshot.isFinal ? AppColors.info : AppColors.textSecondary)
                
                Spacer()
            }
        }
        .padding(AppLayout.itemSpacing)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surfaceElevated)
        )
    }
}

struct TeamScoreRow: View {
    let name: String
    let score: Int
    let isServing: Bool
    
    var body: some View {
        HStack {
            if isServing {
                Image(systemName: "volleyball.fill")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.warning)
            }
            
            Text(name)
                .font(AppTypography.callout)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
            
            Spacer()
            
            Text("\(score)")
                .font(AppTypography.scoreMedium)
                .foregroundColor(AppColors.textPrimary)
                .monospacedDigit()
        }
    }
}

// MARK: - Empty State Views
struct EmptyQueuePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(AppColors.textMuted)
            
            Text("No matches queued")
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

struct WaitingForMatchView: View {
    let match: MatchItem?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEXT MATCH")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(AppColors.textMuted)
            
            if let match = match {
                Text(match.displayName)
                    .font(AppTypography.callout)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(2)
                
                if let time = match.scheduledTime {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(time)
                            .font(AppTypography.caption)
                    }
                    .foregroundColor(AppColors.textSecondary)
                }
            } else {
                Text("Waiting...")
                    .font(AppTypography.callout)
                    .foregroundColor(AppColors.textSecondary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppLayout.itemSpacing)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .fill(AppColors.surfaceElevated)
        )
    }
}

// MARK: - Queue Preview
struct QueuePreview: View {
    let matches: [MatchItem]
    let remaining: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UP NEXT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(AppColors.textMuted)
            
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(AppColors.textMuted)
                        .frame(width: 20)
                    
                    Text(match.shortDisplayName)
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(1)
                    
                    Spacer()
                }
            }
            
            if remaining > matches.count {
                Text("+ \(remaining - matches.count) more")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
                    .italic()
            }
        }
    }
}

// MARK: - Control Buttons
struct CardControls: View {
    let isPolling: Bool
    let hasQueue: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onSkipPrevious: () -> Void
    let onSkipNext: () -> Void
    let onEditQueue: () -> Void
    let onCopyURL: () -> Void
    
    var body: some View {
        VStack(spacing: AppLayout.smallSpacing) {
            // Navigation row
            HStack(spacing: 8) {
                SmallButton(icon: "backward.fill", label: "Prev", action: onSkipPrevious)
                    .disabled(!hasQueue)
                
                if isPolling {
                    SmallButton(icon: "stop.fill", label: "Stop", color: AppColors.error, action: onStop)
                } else {
                    SmallButton(icon: "play.fill", label: "Go", color: AppColors.success, action: onStart)
                        .disabled(!hasQueue)
                }
                
                SmallButton(icon: "forward.fill", label: "Next", action: onSkipNext)
                    .disabled(!hasQueue)
            }
            
            // Action row
            HStack(spacing: 8) {
                SmallButton(icon: "list.bullet.clipboard", label: "Edit Queue", color: AppColors.warning, expanded: true, action: onEditQueue)
                SmallButton(icon: "link", label: "Copy URL", expanded: true, action: onCopyURL)
            }
        }
    }
}

struct SmallButton: View {
    let icon: String
    let label: String
    var color: Color = AppColors.primary
    var expanded: Bool = false
    let action: () -> Void
    
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? color : AppColors.textMuted)
            .frame(maxWidth: expanded ? .infinity : nil)
            .padding(.horizontal, expanded ? 12 : 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                    .fill(isHovered && isEnabled ? color.opacity(0.15) : color.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                    .stroke(color.opacity(isEnabled ? 0.3 : 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

#Preview {
    let court = Court(
        id: 1,
        name: "Core 1",
        queue: [
            MatchItem(apiURL: URL(string: "https://example.com")!, team1Name: "Smith/Johnson", team2Name: "Williams/Davis"),
            MatchItem(apiURL: URL(string: "https://example.com")!, team1Name: "Anderson/Lee", team2Name: "Chen/Park")
        ],
        activeIndex: 0,
        status: .live,
        lastSnapshot: ScoreSnapshot(
            courtId: 1,
            matchId: 1,
            status: "In Progress",
            setNumber: 2,
            team1Name: "Smith/Johnson",
            team2Name: "Williams/Davis",
            team1Score: 15,
            team2Score: 12,
            serve: "home",
            setHistory: [SetScore(setNumber: 1, team1Score: 21, team2Score: 18, isComplete: true)],
            timestamp: Date()
        ),
        liveSince: Date().addingTimeInterval(-300)
    )
    
    CourtCard(
        court: court,
        onStart: {},
        onStop: {},
        onSkipNext: {},
        onSkipPrevious: {},
        onEditQueue: {},
        onRename: {},
        onCopyURL: {}
    )
    .frame(width: 380)
    .padding()
    .background(AppColors.background)
}
