//
//  NotificationService.swift
//  MultiCourtScore v2
//
//  Handles email/webhook notifications for critical events
//

import Foundation

/// Service for sending notifications about critical events
@MainActor
class NotificationService: ObservableObject {
    static let shared = NotificationService()
    
    // MARK: - Settings
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "notificationEnabled") }
    }
    @Published var emailAddress: String {
        didSet { UserDefaults.standard.set(emailAddress, forKey: "notificationEmail") }
    }
    @Published var webhookURL: String {
        didSet { UserDefaults.standard.set(webhookURL, forKey: "notificationWebhook") }
    }
    @Published var notifyOnCourtChange: Bool {
        didSet { UserDefaults.standard.set(notifyOnCourtChange, forKey: "notifyCourtChange") }
    }
    @Published var notifyOnMatchComplete: Bool {
        didSet { UserDefaults.standard.set(notifyOnMatchComplete, forKey: "notifyMatchComplete") }
    }
    
    // MARK: - Recent notifications (for UI display)
    @Published var recentNotifications: [NotificationEvent] = []
    
    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "notificationEnabled")
        emailAddress = UserDefaults.standard.string(forKey: "notificationEmail") ?? ""
        webhookURL = UserDefaults.standard.string(forKey: "notificationWebhook") ?? ""
        notifyOnCourtChange = UserDefaults.standard.object(forKey: "notifyCourtChange") as? Bool ?? true
        notifyOnMatchComplete = UserDefaults.standard.object(forKey: "notifyMatchComplete") as? Bool ?? false
    }
    
    // MARK: - Public API
    
    func sendCourtChangeAlert(_ event: CourtChangeEvent) async {
        guard isEnabled && notifyOnCourtChange else { return }
        
        let notification = NotificationEvent(
            title: event.isLiveMatch ? "🔴 LIVE Match Moved!" : "⚠️ Match Court Changed",
            message: event.description,
            urgency: event.urgency,
            timestamp: event.timestamp
        )
        
        recentNotifications.insert(notification, at: 0)
        if recentNotifications.count > 20 {
            recentNotifications.removeLast()
        }
        
        await sendNotification(notification)
    }
    
    func sendMatchCompleteAlert(matchLabel: String, winner: String, cameraId: Int) async {
        guard isEnabled && notifyOnMatchComplete else { return }
        
        let notification = NotificationEvent(
            title: "✅ Match Completed",
            message: "\(matchLabel) finished. Winner: \(winner). Camera: \(CourtNaming.defaultName(for: cameraId))",
            urgency: .info,
            timestamp: Date()
        )
        
        recentNotifications.insert(notification, at: 0)
        if recentNotifications.count > 20 {
            recentNotifications.removeLast()
        }
        
        await sendNotification(notification)
    }
    
    func sendTestNotification() async {
        let notification = NotificationEvent(
            title: "🧪 Test Notification",
            message: "This is a test notification from MultiCourtScore. If you received this, notifications are working!",
            urgency: .info,
            timestamp: Date()
        )
        
        await sendNotification(notification)
    }
    
    // MARK: - Private
    
    private func sendNotification(_ notification: NotificationEvent) async {
        // Try webhook first (most reliable)
        if !webhookURL.isEmpty {
            await sendWebhook(notification)
        }
        
        // Log to console
        print("📧 Notification: [\(notification.urgency)] \(notification.title) - \(notification.message)")
    }
    
    static let iso8601Formatter = ISO8601DateFormatter()
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private func sendWebhook(_ notification: NotificationEvent) async {
        guard let url = URL(string: webhookURL) else {
            print("⚠️ Invalid webhook URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0

        let payload: [String: Any] = [
            "title": notification.title,
            "message": notification.message,
            "urgency": String(describing: notification.urgency),
            "timestamp": Self.iso8601Formatter.string(from: notification.timestamp),
            "app": "MultiCourtScore"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("✅ Webhook notification sent successfully")
            } else {
                print("⚠️ Webhook returned non-200 status")
            }
        } catch {
            print("⚠️ Webhook notification failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Notification Event

struct NotificationEvent: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let urgency: NotificationUrgency
    let timestamp: Date
    
    var formattedTime: String {
        NotificationService.timeFormatter.string(from: timestamp)
    }
}
