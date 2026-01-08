//
//  NotificationSettingsView.swift
//  MultiCourtScore v2
//
//  UI for configuring notification settings
//

import SwiftUI

struct NotificationSettingsView: View {
    @StateObject private var notificationService = NotificationService.shared
    @State private var showTestAlert = false
    @State private var testAlertMessage = ""
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Notifications", isOn: $notificationService.isEnabled)
                    .toggleStyle(.switch)
            } header: {
                Text("General")
            } footer: {
                Text("Enable or disable all notifications from MultiCourtScore")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Webhook URL")
                        .font(.headline)
                    
                    TextField("https://hooks.zapier.com/...", text: $notificationService.webhookURL)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Use a service like IFTTT, Zapier, or Make to receive notifications via email, SMS, or other channels.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                
                Button {
                    Task {
                        await notificationService.sendTestNotification()
                        testAlertMessage = "Test notification sent! Check your webhook endpoint."
                        showTestAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text("Send Test Notification")
                    }
                }
                .disabled(notificationService.webhookURL.isEmpty || !notificationService.isEnabled)
            } header: {
                Text("Webhook Configuration")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup Instructions:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Text("1. Create a webhook at IFTTT.com, Zapier.com, or Make.com")
                    Text("2. Configure it to send you an email or SMS")
                    Text("3. Copy the webhook URL and paste it above")
                    Text("4. Click 'Send Test Notification' to verify")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            
            Section {
                Toggle("Court Changes", isOn: $notificationService.notifyOnCourtChange)
                    .toggleStyle(.switch)
                
                Toggle("Match Completions", isOn: $notificationService.notifyOnMatchComplete)
                    .toggleStyle(.switch)
            } header: {
                Text("Notification Types")
            } footer: {
                Text("Choose which events trigger notifications")
            }
            
            if !notificationService.recentNotifications.isEmpty {
                Section {
                    ForEach(notificationService.recentNotifications.prefix(10)) { notification in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(notification.title)
                                    .font(.headline)
                                Spacer()
                                Text(notification.formattedTime)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(notification.message)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Recent Notifications")
                }
            }
        }
        .navigationTitle("Notification Settings")
        .alert("Test Notification", isPresented: $showTestAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(testAlertMessage)
        }
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
}
