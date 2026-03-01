//
//  VBLSignalRClientTests.swift
//  MultiCourtScoreTests
//
//  Unit tests for VBLSignalRClient supporting types
//

import Testing
import Foundation
@testable import MultiCourtScore

// MARK: - SignalRStatus Display Label Tests

struct SignalRStatusDisplayLabelTests {

    @Test func disabled_returnsDisabled() {
        #expect(SignalRStatus.disabled.displayLabel == "Disabled")
    }

    @Test func noCredentials_returnsNoCredentials() {
        #expect(SignalRStatus.noCredentials.displayLabel == "No Credentials")
    }

    @Test func connecting_returnsConnecting() {
        #expect(SignalRStatus.connecting.displayLabel == "Connecting...")
    }

    @Test func connected_returnsConnected() {
        #expect(SignalRStatus.connected.displayLabel == "Connected")
    }

    @Test func reconnecting_includesAttemptNumber() {
        #expect(SignalRStatus.reconnecting(attempt: 3).displayLabel == "Reconnecting (3)...")
    }

    @Test func failed_includesReason() {
        #expect(SignalRStatus.failed(reason: "Auth failed").displayLabel == "Failed: Auth failed")
    }
}

// MARK: - SignalRStatus Color Tests

struct SignalRStatusColorTests {

    @Test func disabled_returnsMutedColor() {
        #expect(SignalRStatus.disabled.statusColor == AppColors.textMuted)
    }

    @Test func noCredentials_returnsMutedColor() {
        #expect(SignalRStatus.noCredentials.statusColor == AppColors.textMuted)
    }

    @Test func connecting_returnsWarningColor() {
        #expect(SignalRStatus.connecting.statusColor == AppColors.warning)
    }

    @Test func connected_returnsSuccessColor() {
        #expect(SignalRStatus.connected.statusColor == AppColors.success)
    }

    @Test func reconnecting_returnsWarningColor() {
        #expect(SignalRStatus.reconnecting(attempt: 1).statusColor == AppColors.warning)
    }

    @Test func failed_returnsErrorColor() {
        #expect(SignalRStatus.failed(reason: "test").statusColor == AppColors.error)
    }
}

// MARK: - SignalRStatus Equatable Tests

struct SignalRStatusEquatableTests {

    @Test func sameStatusesAreEqual() {
        #expect(SignalRStatus.connected == SignalRStatus.connected)
        #expect(SignalRStatus.disabled == SignalRStatus.disabled)
        #expect(SignalRStatus.reconnecting(attempt: 2) == SignalRStatus.reconnecting(attempt: 2))
    }

    @Test func differentStatusesAreNotEqual() {
        #expect(SignalRStatus.connected != SignalRStatus.connecting)
        #expect(SignalRStatus.reconnecting(attempt: 1) != SignalRStatus.reconnecting(attempt: 2))
        #expect(SignalRStatus.failed(reason: "a") != SignalRStatus.failed(reason: "b"))
    }
}

// MARK: - AnyCodable Tests

struct AnyCodableTests {

    @Test func decodesString() throws {
        let json = #""hello""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        #expect(decoded.value as? String == "hello")
    }

    @Test func decodesInt() throws {
        let json = "42".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        #expect(decoded.value as? Int == 42)
    }

    @Test func decodesBool() throws {
        let json = "true".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        #expect(decoded.value as? Bool == true)
    }

    @Test func decodesDouble() throws {
        let json = "3.14".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let val = decoded.value as? Double
        #expect(val != nil)
        if let val { #expect(abs(val - 3.14) < 0.001) }
    }

    @Test func decodesNull() throws {
        let json = "null".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        #expect(decoded.value is NSNull)
    }

    @Test func decodesArray() throws {
        let json = #"[1, "two", true]"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let arr = decoded.value as? [Any]
        #expect(arr?.count == 3)
        #expect(arr?[0] as? Int == 1)
        #expect(arr?[1] as? String == "two")
        #expect(arr?[2] as? Bool == true)
    }

    @Test func decodesDictionary() throws {
        let json = #"{"name": "test", "score": 10}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let dict = decoded.value as? [String: Any]
        #expect(dict?["name"] as? String == "test")
        #expect(dict?["score"] as? Int == 10)
    }

    @Test func decodesNestedStructure() throws {
        let json = #"{"data": {"items": [1, 2, 3], "active": true}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let dict = decoded.value as? [String: Any]
        let data = dict?["data"] as? [String: Any]
        let items = data?["items"] as? [Any]
        #expect(items?.count == 3)
        #expect(data?["active"] as? Bool == true)
    }
}

// MARK: - SignalR Frame Splitting Tests

struct SignalRFrameSplittingTests {

    @Test func splitsSingleFrame() async {
        let text = #"{"type":6}"# + "\u{1E}"
        let frames = await VBLSignalRClient.splitFrames(text)
        #expect(frames.count == 1)
        #expect(frames[0] == #"{"type":6}"#)
    }

    @Test func splitsMultipleFrames() async {
        let text = #"{"type":6}"# + "\u{1E}" + #"{"type":1,"target":"StoreMutation","arguments":["test"]}"# + "\u{1E}"
        let frames = await VBLSignalRClient.splitFrames(text)
        #expect(frames.count == 2)
    }

    @Test func handlesEmptyString() async {
        let frames = await VBLSignalRClient.splitFrames("")
        #expect(frames.isEmpty)
    }

    @Test func handlesOnlySeparators() async {
        let frames = await VBLSignalRClient.splitFrames("\u{1E}\u{1E}\u{1E}")
        #expect(frames.isEmpty)
    }

    @Test func handlesFrameWithoutTrailingSeparator() async {
        let text = #"{"type":6}"#
        let frames = await VBLSignalRClient.splitFrames(text)
        #expect(frames.count == 1)
    }
}

// MARK: - SignalR Message Type Parsing Tests

struct SignalRMessageTypeTests {

    @Test func parsesInvocationType() async {
        let frame = #"{"type":1,"target":"StoreMutation","arguments":["test",{}]}"#
        let type = await VBLSignalRClient.parseMessageType(from: frame)
        #expect(type == 1)
    }

    @Test func parsesPingType() async {
        let frame = #"{"type":6}"#
        let type = await VBLSignalRClient.parseMessageType(from: frame)
        #expect(type == 6)
    }

    @Test func parsesCloseType() async {
        let frame = #"{"type":7,"error":"Server shutting down"}"#
        let type = await VBLSignalRClient.parseMessageType(from: frame)
        #expect(type == 7)
    }

    @Test func returnsNilForHandshakeFrame() async {
        let frame = #"{}"#
        let type = await VBLSignalRClient.parseMessageType(from: frame)
        #expect(type == nil)
    }

    @Test func returnsNilForInvalidJSON() async {
        let frame = "not json"
        let type = await VBLSignalRClient.parseMessageType(from: frame)
        #expect(type == nil)
    }
}

// MARK: - SignalRError Tests

struct SignalRErrorTests {

    @Test func authFailed_hasDescription() {
        let error = SignalRError.authFailed
        #expect(error.localizedDescription == "Authentication failed")
    }

    @Test func negotiateFailed_hasDescription() {
        let error = SignalRError.negotiateFailed
        #expect(error.localizedDescription == "Negotiate failed")
    }

    @Test func handshakeFailed_hasDescription() {
        let error = SignalRError.handshakeFailed
        #expect(error.localizedDescription == "Handshake failed")
    }

    @Test func notAuthenticated_hasDescription() {
        let error = SignalRError.notAuthenticated
        #expect(error.localizedDescription == "Not authenticated")
    }
}
