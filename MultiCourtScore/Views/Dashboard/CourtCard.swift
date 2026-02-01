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
        Group {
            switch court.status {
            case .live:
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                    .fill(AppColors.surface)
            case .idle:
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                    .fill(AppColors.surface)
            case .error:
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                    .fill(AppColors.surface)
            default:
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                    .fill(AppColors.surface)
            }
        }
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

            Spacer(minLength: 0)

            Divider()
                .overlay(AppColors.border)

            // Footer: set info + match ID
            cardFooter
                .padding(.horizontal, AppLayout.cardPadding)
                .padding(.vertical, 8)
        }
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
        HStack {
            Text(court.displayName)
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)

            Spacer()

            StatusBadge(label: statusLabel, color: statusColor, isLive: court.status == .live)
        }
    }

    // MARK: - Score Rows

    @ViewBuilder
    private func scoreRows(snapshot: ScoreSnapshot) -> some View {
        VStack(spacing: 6) {
            teamRow(
                seed: snapshot.team1Seed,
                name: snapshot.team1Name,
                isServing: snapshot.serve == "home",
                score: currentSetScore(for: .team1, snapshot: snapshot)
            )

            teamRow(
                seed: snapshot.team2Seed,
                name: snapshot.team2Name,
                isServing: snapshot.serve == "away",
                score: currentSetScore(for: .team2, snapshot: snapshot)
            )
        }
    }

    private enum Team { case team1, team2 }

    private func currentSetScore(for team: Team, snapshot: ScoreSnapshot) -> Int {
        guard let lastSet = snapshot.setHistory.last, !lastSet.isComplete else {
            return 0
        }
        return team == .team1 ? lastSet.team1Score : lastSet.team2Score
    }

    private func teamRow(seed: String?, name: String, isServing: Bool, score: Int) -> some View {
        HStack(spacing: 8) {
            // Seed badge
            if let seed = seed, !seed.isEmpty {
                SeedBadge(seed: seed)
            }

            // Team name
            Text(abbreviateName(name))
                .font(AppTypography.callout)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)

            // Serve indicator
            if isServing {
                Image(systemName: "volleyball.fill")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.warning)
            }

            Spacer()

            // Score
            Text("\(score)")
                .font(AppTypography.scoreCompact)
                .foregroundColor(AppColors.textPrimary)
                .monospacedDigit()
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
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(AppColors.textMuted)

            if let match = court.currentMatch {
                Text(abbreviatedDisplayName(for: match))
                    .font(AppTypography.callout)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(2)
            } else {
                Text("Waiting...")
                    .font(AppTypography.callout)
                    .foregroundColor(AppColors.textSecondary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var cardFooter: some View {
        HStack {
            if let snapshot = court.lastSnapshot {
                let setsWon = snapshot.totalSetsWon
                Text("Set \(snapshot.setNumber) | \(setsWon.team1)-\(setsWon.team2)")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            } else {
                Text("\(court.queue.count) match\(court.queue.count == 1 ? "" : "es") queued")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textMuted)
            }

            Spacer()

            if let match = court.currentMatch {
                if let courtNum = match.courtNumber, !courtNum.isEmpty {
                    Text("Ct \(courtNum)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppColors.warning))
                }

                if let day = match.startDate, !day.isEmpty {
                    Text(day)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(courtCardDayColor(for: day)))
                }

                if let matchNum = match.matchNumber, !matchNum.isEmpty {
                    Text("M\(matchNum)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(AppColors.textMuted)
                }
            }
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

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(isLive ? 1.8 : 1)
                        .opacity(isLive ? 0 : 1)
                )
                .animation(isLive ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: isLive)

            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(AppColors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isConnected ? AppColors.success : AppColors.error)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill((isConnected ? AppColors.success : AppColors.error).opacity(0.15))
        )
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
