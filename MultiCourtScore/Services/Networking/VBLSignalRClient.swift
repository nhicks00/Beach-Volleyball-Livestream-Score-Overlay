//
//  VBLSignalRClient.swift
//  MultiCourtScore v2
//
//  SignalR client for receiving live VBL score mutations.
//  Phase 1: connect, log all StoreMutation messages for schema discovery.
//  Polling continues unchanged as primary data source.
//

import Foundation
import SwiftUI

// MARK: - Connection Status

enum SignalRStatus: Equatable {
    case disabled
    case noCredentials
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)

    var displayLabel: String {
        switch self {
        case .disabled: return "Disabled"
        case .noCredentials: return "No Credentials"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))..."
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    var statusColor: Color {
        switch self {
        case .disabled: return AppColors.textMuted
        case .noCredentials: return AppColors.textMuted
        case .connecting: return AppColors.warning
        case .connected: return AppColors.success
        case .reconnecting: return AppColors.warning
        case .failed: return AppColors.error
        }
    }
}

// MARK: - Delegate Protocol

@MainActor protocol SignalRDelegate: AnyObject {
    func signalRDidReceiveMutation(name: String, payload: Any)
    func signalRStatusDidChange(_ status: SignalRStatus)
}

// MARK: - Errors

enum SignalRError: Error, LocalizedError {
    case authFailed
    case notAuthenticated
    case negotiateFailed
    case handshakeFailed

    var errorDescription: String? {
        switch self {
        case .authFailed: return "Authentication failed"
        case .notAuthenticated: return "Not authenticated"
        case .negotiateFailed: return "Negotiate failed"
        case .handshakeFailed: return "Handshake failed"
        }
    }
}

// MARK: - AnyCodable Helper

/// Lightweight wrapper for decoding heterogeneous JSON values.
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }
}

// MARK: - SignalR Client Actor

actor VBLSignalRClient {
    // MARK: - Constants
    private static let apiBase = "https://volleyballlife-api-dot-net-8.azurewebsites.net"
    private static let loginURL = URL(string: "\(apiBase)/account/login")!
    private static let negotiateURL = URL(string: "\(apiBase)/live/negotiate?negotiateVersion=1")!
    private static let recordSeparator = "\u{1E}"
    private static let handshakePayload = #"{"protocol":"json","version":1}"# + "\u{1E}"

    // MARK: - State
    private weak var delegate: (any SignalRDelegate)?
    private var storedCredentials: ConfigStore.VBLCredentials?
    private var jwtToken: String?
    private var cookies: [HTTPCookie] = []
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isRunning = false
    private var reconnectAttempt = 0

    // MARK: - Init

    init(delegate: any SignalRDelegate) {
        self.delegate = delegate
    }

    // MARK: - Public API

    func connect(credentials: ConfigStore.VBLCredentials) {
        storedCredentials = credentials
        isRunning = true
        reconnectAttempt = 0
        Task { await internalConnect() }
    }

    func disconnect() {
        isRunning = false
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        jwtToken = nil
        cookies = []
        updateStatus(.disabled)
    }

    // MARK: - Internal Connection Flow

    private func internalConnect() async {
        guard isRunning else { return }

        updateStatus(.connecting)

        do {
            // Step 1: Authenticate
            guard let creds = storedCredentials else {
                updateStatus(.noCredentials)
                return
            }
            try await authenticate(credentials: creds)

            // Step 2: Negotiate
            let (wsURL, accessToken) = try await negotiate()

            // Step 3: Connect WebSocket + handshake
            try await connectWebSocket(url: wsURL, token: accessToken)

            // Step 4: Start receive + ping loops
            reconnectAttempt = 0
            updateStatus(.connected)
            startReceiveLoop()
            startPingLoop()

        } catch SignalRError.authFailed {
            updateStatus(.failed(reason: "Auth failed"))
        } catch SignalRError.negotiateFailed {
            await handleDisconnect(reason: "Negotiate failed")
        } catch SignalRError.handshakeFailed {
            await handleDisconnect(reason: "Handshake failed")
        } catch is CancellationError {
            // Intentional disconnect, do nothing
        } catch {
            await handleDisconnect(reason: error.localizedDescription)
        }
    }

    // MARK: - Authentication

    private func authenticate(credentials: ConfigStore.VBLCredentials) async throws {
        var request = URLRequest(url: Self.loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["username": credentials.username, "password": credentials.password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SignalRError.authFailed
        }

        // Extract JWT from response body
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["access_token"] as? String ?? json["accessToken"] as? String {
            jwtToken = token
        } else {
            throw SignalRError.authFailed
        }

        // Extract cookies
        if let headerFields = httpResponse.allHeaderFields as? [String: String],
           let url = httpResponse.url {
            cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        }

        print("[SignalR] Authenticated as \(credentials.username)")
    }

    // MARK: - Negotiate

    private func negotiate() async throws -> (url: URL, accessToken: String) {
        guard let jwt = jwtToken else {
            throw SignalRError.notAuthenticated
        }

        var request = URLRequest(url: Self.negotiateURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        // Attach cookies
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in cookieHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SignalRError.negotiateFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String,
              let accessToken = json["accessToken"] as? String,
              let url = URL(string: urlString) else {
            throw SignalRError.negotiateFailed
        }

        print("[SignalR] Negotiated, connecting to Azure SignalR")
        return (url, accessToken)
    }

    // MARK: - WebSocket Connect + Handshake

    private func connectWebSocket(url: URL, token: String) async throws {
        // Build WebSocket URL with access_token query parameter
        // Azure SignalR returns https:// URLs — convert to wss:// for WebSocket
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "access_token", value: token))
        components.queryItems = queryItems

        guard let wsURL = components.url else {
            throw SignalRError.negotiateFailed
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: wsURL)
        task.resume()
        webSocketTask = task

        // Send handshake
        try await task.send(.string(Self.handshakePayload))

        // Receive handshake response
        let message = try await task.receive()
        switch message {
        case .string(let text):
            // Handshake ack is `{}\x1E` or `{"error":"..."}\x1E`
            let frames = text.components(separatedBy: Self.recordSeparator)
                .filter { !$0.isEmpty }
            guard let first = frames.first,
                  let frameData = first.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any] else {
                throw SignalRError.handshakeFailed
            }
            if let error = json["error"] as? String {
                print("[SignalR] Handshake error: \(error)")
                throw SignalRError.handshakeFailed
            }
            print("[SignalR] Handshake complete")
        case .data:
            throw SignalRError.handshakeFailed
        @unknown default:
            throw SignalRError.handshakeFailed
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self.processFrames(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.processFrames(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        await self.handleDisconnect(reason: "Receive error")
                    }
                    break
                }
            }
        }
    }

    private func processFrames(_ text: String) {
        let frames = text.components(separatedBy: Self.recordSeparator)
            .filter { !$0.isEmpty }

        for frame in frames {
            guard let data = frame.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? Int else {
                continue
            }

            switch type {
            case 1: // Invocation
                handleInvocation(json: json, rawFrame: frame)
            case 6: // Ping
                break // Server ping, no response needed (our ping loop handles keep-alive)
            case 7: // Close
                let reason = json["error"] as? String ?? "Server closed"
                print("[SignalR] Server close: \(reason)")
                if let allowReconnect = json["allowReconnect"] as? Bool, allowReconnect {
                    Task { await handleDisconnect(reason: reason) }
                } else {
                    Task { await handleDisconnect(reason: reason) }
                }
            default:
                print("[SignalR] Unknown message type: \(type)")
            }
        }
    }

    // MARK: - Invocation Handler

    private func handleInvocation(json: [String: Any], rawFrame: String) {
        guard let target = json["target"] as? String else { return }
        let args = json["arguments"] as? [Any] ?? []

        switch target {
        case "StoreMutation":
            let mutationName = args.first as? String ?? "(unknown)"
            let payload = args.count > 1 ? args[1] : NSNull()
            print("[SignalR] StoreMutation: \(mutationName)")
            Task { @MainActor [weak delegate] in
                delegate?.signalRDidReceiveMutation(name: mutationName, payload: payload)
            }

        case "StoreAction":
            let actionName = args.first as? String ?? "(unknown)"
            print("[SignalR] StoreAction: \(actionName)")

        case "NoUser":
            print("[SignalR] NoUser — session may have expired")
            Task { await handleReauthentication() }

        case "consoleLog":
            let msg = args.first as? String ?? ""
            print("[SignalR] consoleLog: \(msg)")

        default:
            print("[SignalR] Invocation: \(target) args=\(args.count)")
        }
    }

    // MARK: - Ping Loop

    private func startPingLoop() {
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(NetworkConstants.signalRPingInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let task = await self.webSocketTask else { break }
                let pingMessage = "{\"type\":6}" + Self.recordSeparator
                try? await task.send(.string(pingMessage))
            }
        }
    }

    // MARK: - Disconnect + Reconnect

    private func handleDisconnect(reason: String) async {
        guard isRunning else { return }

        // Clean up existing connection
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        reconnectAttempt += 1
        let delay = min(
            NetworkConstants.signalRMaxReconnectDelay,
            NetworkConstants.signalRBaseReconnectDelay * pow(2.0, Double(reconnectAttempt - 1))
        )

        updateStatus(.reconnecting(attempt: reconnectAttempt))
        print("[SignalR] Reconnecting in \(Int(delay))s (attempt \(reconnectAttempt)) — \(reason)")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.internalConnect()
        }
    }

    private func handleReauthentication() async {
        print("[SignalR] Re-authenticating...")
        jwtToken = nil
        cookies = []

        // Clean up and reconnect (will re-auth on next connect)
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        reconnectAttempt = 0
        await internalConnect()
    }

    // MARK: - Status Updates

    private func updateStatus(_ status: SignalRStatus) {
        Task { @MainActor [weak delegate] in
            delegate?.signalRStatusDidChange(status)
        }
    }

    // MARK: - Test Helpers

    /// Split a raw SignalR frame string by the record separator. Exposed for testing.
    static func splitFrames(_ text: String) -> [String] {
        text.components(separatedBy: recordSeparator).filter { !$0.isEmpty }
    }

    /// Parse SignalR message type from a JSON frame. Exposed for testing.
    static func parseMessageType(from frame: String) -> Int? {
        guard let data = frame.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? Int else {
            return nil
        }
        return type
    }
}
