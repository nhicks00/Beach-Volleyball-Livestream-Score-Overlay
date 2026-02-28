//
//  CourtCard.swift
//  MultiCourtScore v2
//
//  Compact dark court card matching HTML mockup design
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
    var isCopied: Bool = false

    @State private var isHovered = false

    // MARK: - Status Styling

    private var statusColor: Color {
        switch court.status {
        case .idle: return AppColors.textMuted
        case .waiting: return AppColors.warning
        case .live: return AppColors.success
        case .finished: return AppColors.info
        case .error: return AppColors.error
        }
    }

    private var statusLabel: String {
        switch court.status {
        case .idle: return "IDLE"
        case .waiting: return "WARMUP"
        case .live: return "LIVE"
        case .finished: return "FINISHED"
        case .error: return "OFFLINE"
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
            .fill(AppColors.surface)
    }

    private var cardBorder: some View {
        Group {
            switch court.status {
            case .idle:
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                    .strokeBorder(statusColor.opacity(0.3), lineWidth: AppLayout.borderWidth)
            case .error:
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                    .strokeBorder(AppColors.error.opacity(0.6), lineWidth: AppLayout.borderWidth)
            default:
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                    .strokeBorder(statusColor.opacity(isHovered ? 0.6 : 0.3), lineWidth: AppLayout.borderWidth)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: court name + status badge
            cardHeader
                .padding(.horizontal, AppLayout.cardPadding)
                .padding(.top, AppLayout.cardPadding)
                .padding(.bottom, 10)

            Divider()
                .overlay(AppColors.border)

            // Score area
            if let snapshot = court.lastSnapshot, court.currentMatch != nil {
                scoreRows(snapshot: snapshot)
                    .padding(.horizontal, AppLayout.cardPadding)
                    .padding(.vertical, 10)
            } else if court.queue.isEmpty {
                emptyState
                    .padding(.horizontal, AppLayout.cardPadding)
                    .padding(.vertical, 16)
            } else {
                nextMatchPreview
                    .padding(.horizontal, AppLayout.cardPadding)
                    .padding(.vertical, 10)
            }

            // Error message
            if let errorMessage = court.errorMessage, !errorMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundColor(AppColors.error)
                .padding(.horizontal, AppLayout.cardPadding)
                .padding(.bottom, 6)
            }

            // Data freshness indicator
            if court.status.isPolling, let lastPoll = court.lastPollTime {
                let staleness = Date().timeIntervalSince(lastPoll)
                if staleness > 10 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 10))
                        Text("Data \(Int(staleness))s old")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(staleness > 30 ? AppColors.error : AppColors.warning)
                    .padding(.horizontal, AppLayout.cardPadding)
                    .padding(.bottom, 4)
                }
            }

            Spacer(minLength: 0)

            Divider()
                .overlay(AppColors.border)

            // Footer: set info + match ID
            cardFooter
                .padding(.horizontal, AppLayout.cardPadding)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(
            color: court.status == .live ? AppColors.success.opacity(0.25) : Color.clear,
            radius: court.status == .live ? 12 : 0
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onEditQueue()
        }
        .contextMenu {
            Button { onStart() } label: {
                Label("Start Polling", systemImage: "play.fill")
            }
            .disabled(court.queue.isEmpty)

            Button { onStop() } label: {
                Label("Stop Polling", systemImage: "stop.fill")
            }

            Divider()

            Button { onSkipPrevious() } label: {
                Label("Previous Match", systemImage: "backward.fill")
            }
            .disabled((court.activeIndex ?? 0) <= 0)

            Button { onSkipNext() } label: {
                Label("Next Match", systemImage: "forward.fill")
            }
            .disabled((court.activeIndex ?? 0) >= court.queue.count - 1)

            Divider()

            Button { onCopyURL() } label: {
                Label("Copy OBS URL", systemImage: "link")
            }

            Button { onRename() } label: {
                Label("Rename...", systemImage: "pencil")
            }
        }
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 10) {
            // Camera name
            Text(court.displayName)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
            
            if let match = court.currentMatch {
                topMetadataBadges(for: match)
            }
            
            Spacer()
            
            // Postmatch countdown timer
            if court.status == .finished, let finishedAt = court.finishedAt {
                PostmatchTimer(finishedAt: finishedAt)
            }
            
            Button {
                onCopyURL()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCopied ? "checkmark" : "link")
                        .font(.system(size: 13, weight: .semibold))
                    Text(isCopied ? "Copied!" : "Copy URL")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(isCopied ? AppColors.success : AppColors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(AppColors.surfaceHover)
                )
            }
            .buttonStyle(.plain)
            .help("Copy overlay URL")

            StatusBadge(label: statusLabel, color: statusColor, isLive: court.status == .live)
        }
    }
    
    @ViewBuilder
    private func topMetadataBadges(for match: MatchItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                courtBadge(for: match)
                matchBadge(for: match)
                timeBadge(for: match)
                dayBadge(for: match)
            }
            
            HStack(spacing: 6) {
                courtBadge(for: match)
                matchBadge(for: match)
                timeBadge(for: match)
            }
            
            HStack(spacing: 6) {
                courtBadge(for: match)
                matchBadge(for: match)
            }
            
            HStack(spacing: 6) {
                courtBadge(for: match)
            }
        }
    }
    
    @ViewBuilder
    private func courtBadge(for match: MatchItem) -> some View {
        if let courtNum = match.courtNumber, !courtNum.isEmpty {
            metadataBadge("Ct \(courtNum)", textColor: .white, fill: AppColors.warning)
        }
    }
    
    @ViewBuilder
    private func matchBadge(for match: MatchItem) -> some View {
        if let matchNum = match.matchNumber, !matchNum.isEmpty {
            let isNumeric = Int(matchNum.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            let label = isNumeric ? "M\(matchNum)" : matchNum
            metadataBadge(label, textColor: .white, fill: AppColors.primary)
        }
    }
    
    @ViewBuilder
    private func timeBadge(for match: MatchItem) -> some View {
        if let startTime = match.scheduledTime, !startTime.isEmpty {
            metadataBadge(startTime, textColor: AppColors.textPrimary, fill: AppColors.surfaceHover)
        }
    }
    
    @ViewBuilder
    private func dayBadge(for match: MatchItem) -> some View {
        if let day = match.startDate, !day.isEmpty {
            metadataBadge(day, textColor: .white, fill: courtCardDayColor(for: day))
        }
    }
    
    private func metadataBadge(_ text: String, textColor: Color, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(textColor)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
    }

    // MARK: - Score Rows

    @ViewBuilder
    private func scoreRows(snapshot: ScoreSnapshot) -> some View {
        VStack(spacing: 12) {
            // Set score summary header
            if snapshot.setHistory.count > 1 || (snapshot.setHistory.count == 1 && snapshot.setHistory[0].isComplete) {
                HStack(spacing: 8) {
                    Text("Set \(snapshot.setNumber)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(AppColors.textMuted)
                    let setsWon = snapshot.totalSetsWon
                    Text("\(setsWon.team1)-\(setsWon.team2)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(AppColors.info)
                    Spacer()
                }
            }

            teamRow(
                seed: snapshot.team1Seed,
                name: snapshot.team1Name,
                isServing: snapshot.serve == "home",
                snapshot: snapshot,
                team: .team1
            )

            teamRow(
                seed: snapshot.team2Seed,
                name: snapshot.team2Name,
                isServing: snapshot.serve == "away",
                snapshot: snapshot,
                team: .team2
            )
        }
    }

    private enum Team { case team1, team2 }

    private func currentSetScore(for team: Team, snapshot: ScoreSnapshot) -> Int {
        if let lastSet = snapshot.setHistory.last {
            return team == .team1 ? lastSet.team1Score : lastSet.team2Score
        }

        // Fallback for payloads without set history.
        return team == .team1 ? snapshot.team1Score : snapshot.team2Score
    }

    private func teamRow(seed: String?, name: String, isServing: Bool, snapshot: ScoreSnapshot, team: Team) -> some View {
        HStack(spacing: 10) {
            // Seed badge
            if let seed = seed, !seed.isEmpty {
                SeedBadge(seed: seed)
            }

            // Team name
            Text(abbreviateName(name))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)

            // Serve indicator
            if isServing {
                Image(systemName: "volleyball.fill")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.warning)
            }

            Spacer()

            // Per-set score history
            HStack(spacing: 0) {
                // Completed sets
                let completedSets = snapshot.setHistory.filter { $0.isComplete }
                ForEach(Array(completedSets.enumerated()), id: \.offset) { idx, set in
                    if idx > 0 {
                        // Subtle divider between sets
                        Rectangle()
                            .fill(AppColors.border)
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 6)
                    }
                    let myScore = team == .team1 ? set.team1Score : set.team2Score
                    let theirScore = team == .team1 ? set.team2Score : set.team1Score
                    let wonSet = myScore > theirScore
                    Text("\(myScore)")
                        .font(.system(size: 15, weight: wonSet ? .bold : .regular, design: .monospaced))
                        .foregroundColor(wonSet ? AppColors.textPrimary : AppColors.textMuted)
                        .monospacedDigit()
                }

                // Divider before current set if there are completed sets
                if !completedSets.isEmpty {
                    Rectangle()
                        .fill(AppColors.border)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 6)
                }

                // Current set score (in-progress)
                let currentScore = currentSetScore(for: team, snapshot: snapshot)
                Text("\(currentScore)")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundColor(AppColors.warning)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundColor(AppColors.textMuted)

            Text("No matches queued")
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Next Match Preview

    private var nextMatchPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT MATCH")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppColors.textMuted)

            if let match = court.currentMatch {
                Text(abbreviatedDisplayName(for: match))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(2)
            } else {
                Text("Waiting...")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var cardFooter: some View {
        HStack(spacing: 10) {
            // Navigation buttons - larger and more prominent
            HStack(spacing: 6) {
                Button {
                    onSkipPrevious()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                        Text("Prev")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor((court.activeIndex ?? 0) <= 0 ? AppColors.textMuted.opacity(0.3) : AppColors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill((court.activeIndex ?? 0) <= 0 ? Color.clear : AppColors.surfaceHover)
                    )
                }
                .buttonStyle(.plain)
                .disabled((court.activeIndex ?? 0) <= 0)
                
                Text("\((court.activeIndex ?? 0) + 1) of \(court.queue.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textMuted)
                    .padding(.horizontal, 4)
                
                Button {
                    onSkipNext()
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor((court.activeIndex ?? 0) >= court.queue.count - 1 ? AppColors.textMuted.opacity(0.3) : AppColors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill((court.activeIndex ?? 0) >= court.queue.count - 1 ? Color.clear : AppColors.surfaceHover)
                    )
                }
                .buttonStyle(.plain)
                .disabled((court.activeIndex ?? 0) >= court.queue.count - 1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(AppColors.surfaceElevated.opacity(0.3))
            .cornerRadius(6)
            
            HStack(spacing: 6) {
                Button {
                    onStart()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Start")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(court.status.isPolling ? AppColors.textMuted : AppColors.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(court.status.isPolling ? Color.clear : AppColors.success.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
                .disabled(court.queue.isEmpty || court.status.isPolling)
                
                Button {
                    onStop()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(court.status.isPolling ? AppColors.error : AppColors.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(court.status.isPolling ? AppColors.error.opacity(0.15) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!court.status.isPolling)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(AppColors.surfaceElevated.opacity(0.3))
            .cornerRadius(6)
            
            Spacer()
        }
    }

    // MARK: - Name Helpers

    private func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func abbreviateName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("winner") || lower.contains("loser") || lower.contains("team ") || lower.contains("match ") || lower.contains("seed ") {
            return name
        }
        let players = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        let abbreviated = players.map { player -> String in
            let cleanedPlayer = cleanName(player)
            let parts = cleanedPlayer.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { return cleanedPlayer }
            let firstName = parts[0]
            let lastName = parts[parts.count - 1]
            return "\(firstName.prefix(1)). \(lastName)"
        }
        return abbreviated.joined(separator: " / ")
    }

    private func abbreviatedDisplayName(for match: MatchItem) -> String {
        if let t1 = match.team1Name, let t2 = match.team2Name, !t1.isEmpty, !t2.isEmpty {
            let team1Display = formatTeamWithSeed(abbreviateName(t1), seed: match.team1Seed)
            let team2Display = formatTeamWithSeed(abbreviateName(t2), seed: match.team2Seed)
            return "\(team1Display) vs \(team2Display)"
        }
        return match.displayName
    }

    private func formatTeamWithSeed(_ name: String, seed: String?) -> String {
        guard let seed = seed, !seed.isEmpty else { return name }
        return "\(name) (\(seed))"
    }

    private func courtCardDayColor(for day: String) -> Color {
        switch day.lowercased().prefix(3) {
        case "sat": return AppColors.info
        case "sun": return AppColors.warning
        case "fri": return AppColors.success
        case "thu": return Color.purple
        default: return AppColors.textMuted
        }
    }
}

// MARK: - Shared Badge Components

struct StatusBadge: View {
    let label: String
    let color: Color
    var isLive: Bool = false

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .opacity(isLive && isPulsing ? 0.3 : 1.0)
                .animation(isLive ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: isPulsing)
                .onAppear {
                    if isLive { isPulsing = true }
                }
                .onChange(of: isLive) { newValue in
                    isPulsing = newValue
                }

            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
    }
}

struct SeedBadge: View {
    let seed: String

    var body: some View {
        Text(seed)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundColor(AppColors.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.surfaceHover)
            )
    }
}

struct ConnectionBadge: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? AppColors.success : AppColors.error)
                .frame(width: 8, height: 8)

            Text(isConnected ? "Connected" : "Disconnected")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isConnected ? AppColors.success : AppColors.error)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill((isConnected ? AppColors.success : AppColors.error).opacity(0.15))
        )
    }
}

// MARK: - Postmatch Countdown Timer

struct PostmatchTimer: View {
    let finishedAt: Date

    var body: some View {
        TimelineView(.periodic(from: finishedAt, by: 1.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(finishedAt)
            let remaining = max(0, Int(AppConfig.holdScoreDuration) - Int(elapsed))
            let minutes = remaining / 60
            let seconds = remaining % 60

            HStack(spacing: 4) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Next \(String(format: "%d:%02d", minutes, seconds))")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .foregroundColor(remaining <= 30 ? AppColors.warning : AppColors.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(remaining <= 30 ? AppColors.warning.opacity(0.15) : AppColors.surfaceHover)
            )
        }
    }
}

// MARK: - Preview

#Preview {
    let court = Court(
        id: 1,
        name: "Core 1",
        queue: [
            MatchItem(apiURL: URL(string: "https://example.com")!, team1Name: "Smith/Johnson", team2Name: "Williams/Davis", team1Seed: "1", team2Seed: "4"),
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
            team1Seed: "1",
            team2Seed: "4",
            team1Score: 1,
            team2Score: 0,
            serve: "home",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 18, isComplete: true),
                SetScore(setNumber: 2, team1Score: 15, team2Score: 12, isComplete: false)
            ],
            timestamp: Date(),
            setsToWin: 2
        ),
        liveSince: Date().addingTimeInterval(-300)
    )

    HStack(spacing: 16) {
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
        .frame(width: 340)

        CourtCard(
            court: Court.create(id: 2),
            onStart: {},
            onStop: {},
            onSkipNext: {},
            onSkipPrevious: {},
            onEditQueue: {},
            onRename: {},
            onCopyURL: {}
        )
        .frame(width: 340)
    }
    .padding()
    .background(AppColors.background)
}
