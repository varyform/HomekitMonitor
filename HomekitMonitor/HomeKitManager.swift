//
//  HomeKitManager.swift
//  HomekitMonitor
//
//  Created by Oleh Khomey on 06.12.2025.
//

import Combine
import Foundation
import HomeKit
import MQTTNIO
import NIOCore
import NIOPosix

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let rawEvent: String
}

struct Subscription: Identifiable, Codable {
    let id: UUID
    let pattern: String
    var lastMatch: Date?
    var matchCount: Int
    var mqttTopic: String
    var mqttPayload: String

    init(pattern: String, mqttTopic: String = "", mqttPayload: String = "") {
        self.id = UUID()
        self.pattern = pattern
        self.lastMatch = nil
        self.matchCount = 0
        self.mqttTopic = mqttTopic
        self.mqttPayload = mqttPayload
    }
}

struct MQTTConfig: Codable {
    var server: String
    var port: Int
    var username: String
    var password: String
    var prefix: String

    init() {
        self.server = "localhost"
        self.port = 1883
        self.username = ""
        self.password = ""
        self.prefix = "homekit"
    }
}

class HomeKitManager: NSObject, ObservableObject {
    private let homeManager = HMHomeManager()

    @Published var homes: [HMHome] = []
    @Published var eventLog: [LogEntry] = []
    @Published var subscriptions: [Subscription] = []
    @Published var mqttConfig = MQTTConfig()
    @Published var mqttConnected = false

    private var mqttClient: MQTTClient?
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    override init() {
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        super.init()
        homeManager.delegate = self
        loadSubscriptions()
        loadMQTTConfig()
        logEvent("HomeKitManager initialized")
    }

    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }

    private func logEvent(_ message: String) {
        let timestamp = Date()
        let timestampStr = ISO8601DateFormatter().string(from: timestamp)
        let logMessage = "[\(timestampStr)] \(message)"
        print(logMessage)

        let entry = LogEntry(timestamp: timestamp, message: logMessage, rawEvent: message)

        DispatchQueue.main.async {
            self.eventLog.append(entry)
            if self.eventLog.count > 1000 {
                self.eventLog.removeFirst(self.eventLog.count - 1000)
            }
            self.checkSubscriptions(for: message, at: timestamp)
        }
    }

    private func logEventAsync(_ message: String) async {
        let timestamp = Date()
        let timestampStr = ISO8601DateFormatter().string(from: timestamp)
        let logMessage = "[\(timestampStr)] \(message)"
        print(logMessage)

        let entry = LogEntry(timestamp: timestamp, message: logMessage, rawEvent: message)

        await MainActor.run {
            self.eventLog.append(entry)
            if self.eventLog.count > 1000 {
                self.eventLog.removeFirst(self.eventLog.count - 1000)
            }
        }
    }

    func addSubscription(pattern: String, mqttTopic: String = "", mqttPayload: String = "") {
        let subscription = Subscription(
            pattern: pattern, mqttTopic: mqttTopic, mqttPayload: mqttPayload)
        DispatchQueue.main.async {
            self.subscriptions.append(subscription)
            self.saveSubscriptions()
        }
    }

    func updateSubscription(id: UUID, mqttTopic: String, mqttPayload: String) {
        if let index = subscriptions.firstIndex(where: { $0.id == id }) {
            subscriptions[index].mqttTopic = mqttTopic
            subscriptions[index].mqttPayload = mqttPayload
            saveSubscriptions()
        }
    }

    func removeSubscription(id: UUID) {
        DispatchQueue.main.async {
            self.subscriptions.removeAll { $0.id == id }
            self.saveSubscriptions()
        }
    }

    private func checkSubscriptions(for message: String, at timestamp: Date) {
        for index in subscriptions.indices {
            let pattern = subscriptions[index].pattern.lowercased()
            if message.lowercased().contains(pattern) {
                subscriptions[index].lastMatch = timestamp
                subscriptions[index].matchCount += 1

                // Extract value from message if present (e.g., "= VALUE")
                if !subscriptions[index].mqttTopic.isEmpty {
                    if let valueRange = message.range(of: "= ") {
                        let valueStart = valueRange.upperBound
                        var valueEnd = message.endIndex
                        if let nextSpace = message[valueStart...].firstIndex(of: " ") {
                            valueEnd = nextSpace
                        }
                        let value = String(message[valueStart..<valueEnd])
                        logEvent("MQTT: Extracted value '\(value)' from message")
                        publishToMQTT(subscription: subscriptions[index], value: value)
                    } else {
                        logEvent("MQTT: No value found in message (missing '= ')")
                    }
                }

                saveSubscriptions()
            }
        }
    }

    private func publishToMQTT(subscription: Subscription, value: String) {
        let topic = "\(mqttConfig.prefix)/\(subscription.mqttTopic)"

        // Trim whitespace from template and replace smart quotes with straight quotes
        let payloadTemplate = subscription.mqttPayload.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let payload = payloadTemplate.replacingOccurrences(of: "{{value}}", with: value)

        let server = mqttConfig.server
        let port = mqttConfig.port

        print("DEBUG: publishToMQTT called - about to create Task.detached")

        Task.detached { [weak self] in
            print("DEBUG: Inside Task.detached")
            guard let self = self else {
                print("DEBUG: self is nil, returning")
                return
            }

            print("DEBUG: About to log MQTT info")
            print("MQTT: Topic=\(topic)")
            print("MQTT: Payload before interpolation=\(payloadTemplate)")
            print("MQTT: Value to interpolate='\(value)'")
            print("MQTT: Payload after interpolation=\(payload)")
            print("MQTT: Server=\(server):\(port)")

            // Validate JSON
            guard let jsonData = payload.data(using: .utf8) else {
                await self.logEventAsync("MQTT: ✗ Failed to encode payload as UTF-8")
                return
            }

            print(
                "MQTT: Payload bytes: \(jsonData.map { String(format: "%02x", $0) }.joined(separator: " "))"
            )
            print("MQTT: Payload length: \(payload.count) chars, \(jsonData.count) bytes")

            do {
                _ = try JSONSerialization.jsonObject(with: jsonData)
                print("MQTT: ✓ JSON validation passed")
            } catch {
                await self.logEventAsync("MQTT: ✗ Invalid JSON - \(error.localizedDescription)")
                print("MQTT: Raw payload: [\(payload)]")
                return
            }

            print("DEBUG: About to start connection/publish")
            do {
                print("DEBUG: Calling connectMQTTIfNeeded with timeout")
                try await withTimeout(seconds: 10) {
                    try await self.connectMQTTIfNeeded()
                }
                print("DEBUG: Connected, about to publish")
                try await withTimeout(seconds: 5) {
                    try await self.mqttClient?.publish(
                        to: topic, payload: ByteBuffer(string: payload), qos: .atLeastOnce,
                        retain: false)
                }
                print("DEBUG: Publish completed")
                await self.logEventAsync("MQTT: ✓ Published successfully")
            } catch is TimeoutError {
                print("DEBUG: Caught TimeoutError")
                await self.logEventAsync("MQTT: ✗ Connection timeout")
                await self.resetMQTTClient()
            } catch {
                print("DEBUG: Caught error: \(error)")
                await self.logEventAsync(
                    "MQTT: ✗ Failed to publish - \(error.localizedDescription)")
                await self.resetMQTTClient()
            }
            print("DEBUG: Task.detached completed")
        }
        print("DEBUG: publishToMQTT function returning")
    }

    private func resetMQTTClient() async {
        mqttClient = nil
        await MainActor.run {
            self.mqttConnected = false
        }
    }

    private func connectMQTTIfNeeded() async throws {
        print("DEBUG: connectMQTTIfNeeded called")
        if mqttClient != nil && mqttConnected {
            print("DEBUG: Already connected, returning")
            return
        }

        print("DEBUG: About to log connection message")
        print("MQTT: Connecting to \(mqttConfig.server):\(mqttConfig.port)...")

        print("DEBUG: Creating MQTTClient configuration")
        let configuration = MQTTClient.Configuration(
            userName: mqttConfig.username.isEmpty ? nil : mqttConfig.username,
            password: mqttConfig.password.isEmpty ? nil : mqttConfig.password
        )

        print("DEBUG: Creating MQTTClient instance")
        let client = MQTTClient(
            host: mqttConfig.server,
            port: mqttConfig.port,
            identifier: "homekit-monitor-\(UUID().uuidString)",
            eventLoopGroupProvider: .createNew,
            configuration: configuration
        )

        print("DEBUG: About to call client.connect()")
        try await client.connect()
        print("DEBUG: client.connect() returned")

        self.mqttClient = client
        print("DEBUG: About to set mqttConnected = true on MainActor")
        await MainActor.run {
            self.mqttConnected = true
        }
        print("DEBUG: About to log success message")
        print("MQTT: ✓ Connected successfully")
        print("DEBUG: connectMQTTIfNeeded completed")
    }

    private func withTimeout<T>(seconds: Int, operation: @escaping () async throws -> T)
        async throws -> T
    {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                return nil
            }

            if let result = try await group.next() {
                group.cancelAll()
                if let value = result {
                    return value
                } else {
                    throw TimeoutError()
                }
            }
            throw TimeoutError()
        }
    }

    struct TimeoutError: Error {}

    func disconnectMQTT() {
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                try await self.mqttClient?.disconnect()
                print("MQTT: Disconnected")
            } catch {
                print("MQTT: Error disconnecting - \(error.localizedDescription)")
            }
            await MainActor.run {
                self.mqttConnected = false
            }
            self.mqttClient = nil
        }
    }

    func reconnectMQTT() {
        disconnectMQTT()
        Task.detached { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? await self.connectMQTTIfNeeded()
        }
    }

    private func saveSubscriptions() {
        if let encoded = try? JSONEncoder().encode(subscriptions) {
            UserDefaults.standard.set(encoded, forKey: "homekit_subscriptions")
        }
    }

    private func loadSubscriptions() {
        if let data = UserDefaults.standard.data(forKey: "homekit_subscriptions"),
            let decoded = try? JSONDecoder().decode([Subscription].self, from: data)
        {
            subscriptions = decoded
        }
    }

    func saveMQTTConfig() {
        if let encoded = try? JSONEncoder().encode(mqttConfig) {
            UserDefaults.standard.set(encoded, forKey: "mqtt_config")
        }
    }

    private func loadMQTTConfig() {
        if let data = UserDefaults.standard.data(forKey: "mqtt_config"),
            let decoded = try? JSONDecoder().decode(MQTTConfig.self, from: data)
        {
            mqttConfig = decoded
        }
    }

    private func getRoomName(for accessory: HMAccessory) -> String {
        return accessory.room?.name ?? "No Room"
    }

    private func setupAccessoryDelegates(for home: HMHome) {
        for accessory in home.accessories {
            accessory.delegate = self
            let room = getRoomName(for: accessory)
            logEvent("Registered delegate for accessory: \(accessory.name) [Room: \(room)]")

            for service in accessory.services {
                logEvent(
                    "Service: \(service.name) (\(service.serviceType)) on \(accessory.name) [Room: \(room)]"
                )

                for characteristic in service.characteristics {
                    logEvent(
                        "Characteristic: \(characteristic.localizedDescription) on \(service.name) [Room: \(room)]"
                    )
                    characteristic.enableNotification(true) { error in
                        if let error = error {
                            self.logEvent(
                                "Failed to enable notifications for \(characteristic.localizedDescription) [Room: \(room)]: \(error.localizedDescription)"
                            )
                        } else {
                            self.logEvent(
                                "Enabled notifications for \(characteristic.localizedDescription) [Room: \(room)]"
                            )
                        }
                    }
                }
            }
        }
    }
}

extension HomeKitManager: HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        logEvent("Home Manager updated homes. Total homes: \(manager.homes.count)")
        DispatchQueue.main.async {
            self.homes = manager.homes
        }

        for home in manager.homes {
            home.delegate = self
            logEvent("Home: \(home.name)")
            setupAccessoryDelegates(for: home)
        }
    }

}

extension HomeKitManager: HMHomeDelegate {
    func homeDidUpdateName(_ home: HMHome) {
        logEvent("Home name updated: \(home.name)")
    }

    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        let room = getRoomName(for: accessory)
        logEvent("Accessory added: \(accessory.name) [Room: \(room)] to home: \(home.name)")
        accessory.delegate = self
        setupAccessoryDelegates(for: home)
    }

    func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        let room = getRoomName(for: accessory)
        logEvent("Accessory removed: \(accessory.name) [Room: \(room)] from home: \(home.name)")
    }

    func home(_ home: HMHome, didAdd user: HMUser) {
        logEvent("User added: \(user.name) to home: \(home.name)")
    }

    func home(_ home: HMHome, didRemove user: HMUser) {
        logEvent("User removed: \(user.name) from home: \(home.name)")
    }

    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        logEvent("Accessory \(accessory.name) moved to room: \(room.name)")
    }

    func home(_ home: HMHome, didAdd room: HMRoom) {
        logEvent("Room added: \(room.name) to home: \(home.name)")
    }

    func home(_ home: HMHome, didRemove room: HMRoom) {
        logEvent("Room removed: \(room.name) from home: \(home.name)")
    }

    func home(_ home: HMHome, didAdd zone: HMZone) {
        logEvent("Zone added: \(zone.name) to home: \(home.name)")
    }

    func home(_ home: HMHome, didRemove zone: HMZone) {
        logEvent("Zone removed: \(zone.name) from home: \(home.name)")
    }

    func home(_ home: HMHome, didAdd serviceGroup: HMServiceGroup) {
        logEvent("Service group added: \(serviceGroup.name) to home: \(home.name)")
    }

    func home(_ home: HMHome, didRemove serviceGroup: HMServiceGroup) {
        logEvent("Service group removed: \(serviceGroup.name) from home: \(home.name)")
    }

    func home(_ home: HMHome, didAdd actionSet: HMActionSet) {
        logEvent("Action set added: \(actionSet.name) to home: \(home.name)")
    }

    func home(_ home: HMHome, didRemove actionSet: HMActionSet) {
        logEvent("Action set removed: \(actionSet.name) from home: \(home.name)")
    }

    func home(_ home: HMHome, didExecuteActionSet actionSet: HMActionSet) {
        logEvent("Action set executed: \(actionSet.name) in home: \(home.name)")
    }

    func home(_ home: HMHome, didAdd trigger: HMTrigger) {
        logEvent("Trigger added: \(trigger.name) to home: \(home.name)")
    }

    func home(_ home: HMHome, didRemove trigger: HMTrigger) {
        logEvent("Trigger removed: \(trigger.name) from home: \(home.name)")
    }

    func home(_ home: HMHome, didUpdate trigger: HMTrigger) {
        logEvent("Trigger updated: \(trigger.name) in home: \(home.name)")
    }
}

extension HomeKitManager: HMAccessoryDelegate {
    func accessoryDidUpdateName(_ accessory: HMAccessory) {
        let room = getRoomName(for: accessory)
        logEvent("Accessory name updated: \(accessory.name) [Room: \(room)]")
    }

    func accessory(_ accessory: HMAccessory, didUpdateNameFor service: HMService) {
        let room = getRoomName(for: accessory)
        logEvent(
            "Service name updated: \(service.name) on accessory: \(accessory.name) [Room: \(room)]")
    }

    func accessory(_ accessory: HMAccessory, didUpdateAssociatedServiceTypeFor service: HMService) {
        let room = getRoomName(for: accessory)
        logEvent(
            "Service type updated for: \(service.name) on accessory: \(accessory.name) [Room: \(room)]"
        )
    }

    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        let room = getRoomName(for: accessory)
        logEvent("Services updated for accessory: \(accessory.name) [Room: \(room)]")
    }

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let status = accessory.isReachable ? "reachable" : "unreachable"
        let room = getRoomName(for: accessory)
        logEvent("Accessory \(accessory.name) [Room: \(room)] is now \(status)")
    }

    func accessory(
        _ accessory: HMAccessory, service: HMService,
        didUpdateValueFor characteristic: HMCharacteristic
    ) {
        let value = characteristic.value ?? "nil"
        let room = getRoomName(for: accessory)
        logEvent(
            "Characteristic updated: \(characteristic.localizedDescription) = \(value) on service: \(service.name) of accessory: \(accessory.name) [Room: \(room)]"
        )
    }
}
