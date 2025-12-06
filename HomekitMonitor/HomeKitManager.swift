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

enum HomeKitEventType: String, Codable {
    case characteristicUpdated
    case accessoryReachabilityChanged
    case accessoryAdded
    case accessoryRemoved
    case homeUpdated
    case roomUpdated
    case serviceUpdated
    case actionSetExecuted
}

struct HomeKitEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: HomeKitEventType
    let accessoryName: String?
    let roomName: String?
    let serviceName: String?
    let characteristicName: String?
    let value: String?

    var displayText: String {
        let timestampStr = ISO8601DateFormatter().string(from: timestamp)
        var parts = ["[\(timestampStr)]", type.rawValue]

        if let characteristic = characteristicName, let service = serviceName,
            let accessory = accessoryName
        {
            parts.append("\(characteristic) = \(value ?? "nil") on \(service) of \(accessory)")
            if let room = roomName {
                parts.append("[Room: \(room)]")
            }
        } else if let accessory = accessoryName {
            parts.append(accessory)
            if let room = roomName {
                parts.append("[Room: \(room)]")
            }
        }

        return parts.joined(separator: " ")
    }
}

struct Subscription: Identifiable, Codable {
    let id: UUID
    let accessoryName: String
    let characteristicName: String
    var lastMatch: Date?
    var matchCount: Int
    var mqttTopic: String
    var mqttPayload: String

    init(
        accessoryName: String, characteristicName: String, mqttTopic: String = "",
        mqttPayload: String = ""
    ) {
        self.id = UUID()
        self.accessoryName = accessoryName
        self.characteristicName = characteristicName
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
    @Published var eventLog: [HomeKitEvent] = []
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
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: nil,
                roomName: nil,
                serviceName: nil,
                characteristicName: nil,
                value: "Initialized"
            ))
    }

    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }

    private func logEvent(_ event: HomeKitEvent) {
        print(event.displayText)

        DispatchQueue.main.async {
            self.eventLog.append(event)
            if self.eventLog.count > 1000 {
                self.eventLog.removeFirst(self.eventLog.count - 1000)
            }
            self.checkSubscriptions(for: event)
        }
    }

    private func logEventAsync(_ event: HomeKitEvent) async {
        print(event.displayText)

        await MainActor.run {
            self.eventLog.append(event)
            if self.eventLog.count > 1000 {
                self.eventLog.removeFirst(self.eventLog.count - 1000)
            }
        }
    }

    func addSubscription(
        accessoryName: String, characteristicName: String, mqttTopic: String = "",
        mqttPayload: String = ""
    ) {
        let subscription = Subscription(
            accessoryName: accessoryName, characteristicName: characteristicName,
            mqttTopic: mqttTopic, mqttPayload: mqttPayload)
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

    private func checkSubscriptions(for event: HomeKitEvent) {
        guard event.type == .characteristicUpdated else { return }
        guard let accessory = event.accessoryName,
            let characteristic = event.characteristicName,
            let value = event.value
        else { return }

        for index in subscriptions.indices {
            if subscriptions[index].accessoryName == accessory
                && subscriptions[index].characteristicName == characteristic
            {
                subscriptions[index].lastMatch = event.timestamp
                subscriptions[index].matchCount += 1

                if !subscriptions[index].mqttTopic.isEmpty {
                    publishToMQTT(subscription: subscriptions[index], value: value)
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
                print("MQTT: ✗ Failed to encode payload as UTF-8")
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
                print("MQTT: ✗ Invalid JSON - \(error.localizedDescription)")
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
                await self.logEventAsync(
                    HomeKitEvent(
                        timestamp: Date(),
                        type: .characteristicUpdated,
                        accessoryName: "MQTT",
                        roomName: nil,
                        serviceName: nil,
                        characteristicName: "Publish",
                        value: "Success"
                    ))
            } catch is TimeoutError {
                print("DEBUG: Caught TimeoutError")
                await self.logEventAsync(
                    HomeKitEvent(
                        timestamp: Date(),
                        type: .characteristicUpdated,
                        accessoryName: "MQTT",
                        roomName: nil,
                        serviceName: nil,
                        characteristicName: "Error",
                        value: "Connection timeout"
                    ))
                await self.resetMQTTClient()
            } catch {
                print("DEBUG: Caught error: \(error)")
                await self.logEventAsync(
                    HomeKitEvent(
                        timestamp: Date(),
                        type: .characteristicUpdated,
                        accessoryName: "MQTT",
                        roomName: nil,
                        serviceName: nil,
                        characteristicName: "Error",
                        value: error.localizedDescription
                    ))
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
            for service in accessory.services {
                for characteristic in service.characteristics {
                    characteristic.enableNotification(true) { error in
                        if let error = error {
                            print(
                                "Failed to enable notifications for \(characteristic.localizedDescription): \(error.localizedDescription)"
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
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: nil,
                roomName: nil,
                serviceName: nil,
                characteristicName: nil,
                value: "\(manager.homes.count) homes"
            ))
        DispatchQueue.main.async {
            self.homes = manager.homes
        }

        for home in manager.homes {
            home.delegate = self
            setupAccessoryDelegates(for: home)
        }
    }

}

extension HomeKitManager: HMHomeDelegate {
    func homeDidUpdateName(_ home: HMHome) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: home.name,
                roomName: nil,
                serviceName: nil,
                characteristicName: "Name Updated",
                value: nil
            ))
    }

    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        let room = getRoomName(for: accessory)
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .accessoryAdded,
                accessoryName: accessory.name,
                roomName: room,
                serviceName: nil,
                characteristicName: nil,
                value: nil
            ))
        accessory.delegate = self
        setupAccessoryDelegates(for: home)
    }

    func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        let room = getRoomName(for: accessory)
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .accessoryRemoved,
                accessoryName: accessory.name,
                roomName: room,
                serviceName: nil,
                characteristicName: nil,
                value: nil
            ))
    }

    func home(_ home: HMHome, didAdd user: HMUser) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "User: \(user.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Added",
                value: nil
            ))
    }

    func home(_ home: HMHome, didRemove user: HMUser) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "User: \(user.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Removed",
                value: nil
            ))
    }

    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .roomUpdated,
                accessoryName: accessory.name,
                roomName: room.name,
                serviceName: nil,
                characteristicName: "Moved",
                value: nil
            ))
    }

    func home(_ home: HMHome, didAdd room: HMRoom) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .roomUpdated,
                accessoryName: nil,
                roomName: room.name,
                serviceName: nil,
                characteristicName: "Added",
                value: nil
            ))
    }

    func home(_ home: HMHome, didRemove room: HMRoom) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .roomUpdated,
                accessoryName: nil,
                roomName: room.name,
                serviceName: nil,
                characteristicName: "Removed",
                value: nil
            ))
    }

    func home(_ home: HMHome, didAdd zone: HMZone) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "Zone: \(zone.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Added",
                value: nil
            ))
    }

    func home(_ home: HMHome, didRemove zone: HMZone) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "Zone: \(zone.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Removed",
                value: nil
            ))
    }

    func home(_ home: HMHome, didAdd serviceGroup: HMServiceGroup) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "ServiceGroup: \(serviceGroup.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Added",
                value: nil
            ))
    }

    func home(_ home: HMHome, didRemove serviceGroup: HMServiceGroup) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "ServiceGroup: \(serviceGroup.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Removed",
                value: nil
            ))
    }

    func home(_ home: HMHome, didAdd actionSet: HMActionSet) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .actionSetExecuted,
                accessoryName: actionSet.name,
                roomName: nil,
                serviceName: nil,
                characteristicName: "Added",
                value: nil
            ))
    }

    func home(_ home: HMHome, didRemove actionSet: HMActionSet) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .actionSetExecuted,
                accessoryName: actionSet.name,
                roomName: nil,
                serviceName: nil,
                characteristicName: "Removed",
                value: nil
            ))
    }

    func home(_ home: HMHome, didExecuteActionSet actionSet: HMActionSet) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .actionSetExecuted,
                accessoryName: actionSet.name,
                roomName: nil,
                serviceName: nil,
                characteristicName: "Executed",
                value: nil
            ))
    }

    func home(_ home: HMHome, didAdd trigger: HMTrigger) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "Trigger: \(trigger.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Added",
                value: nil
            ))
    }

    func home(_ home: HMHome, didRemove trigger: HMTrigger) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "Trigger: \(trigger.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Removed",
                value: nil
            ))
    }

    func home(_ home: HMHome, didUpdate trigger: HMTrigger) {
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .homeUpdated,
                accessoryName: "Trigger: \(trigger.name)",
                roomName: nil,
                serviceName: nil,
                characteristicName: "Updated",
                value: nil
            ))
    }
}

extension HomeKitManager: HMAccessoryDelegate {
    func accessoryDidUpdateName(_ accessory: HMAccessory) {
        let room = getRoomName(for: accessory)
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .serviceUpdated,
                accessoryName: accessory.name,
                roomName: room,
                serviceName: nil,
                characteristicName: "Name Updated",
                value: nil
            ))
    }

    func accessory(_ accessory: HMAccessory, didUpdateNameFor service: HMService) {
        let room = getRoomName(for: accessory)
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .serviceUpdated,
                accessoryName: accessory.name,
                roomName: room,
                serviceName: service.name,
                characteristicName: "Name Updated",
                value: nil
            ))
    }

    func accessory(_ accessory: HMAccessory, didUpdateAssociatedServiceTypeFor service: HMService) {
        let room = getRoomName(for: accessory)
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .serviceUpdated,
                accessoryName: accessory.name,
                roomName: room,
                serviceName: service.name,
                characteristicName: "Type Updated",
                value: nil
            ))
    }

    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        let room = getRoomName(for: accessory)
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .serviceUpdated,
                accessoryName: accessory.name,
                roomName: room,
                serviceName: nil,
                characteristicName: "Services Updated",
                value: nil
            ))
    }

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let status = accessory.isReachable ? "reachable" : "unreachable"
        let room = getRoomName(for: accessory)
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .accessoryReachabilityChanged,
                accessoryName: accessory.name,
                roomName: room,
                serviceName: nil,
                characteristicName: "Reachability",
                value: status
            ))
    }

    func accessory(
        _ accessory: HMAccessory, service: HMService,
        didUpdateValueFor characteristic: HMCharacteristic
    ) {
        let value = "\(characteristic.value ?? "nil")"
        let room = getRoomName(for: accessory)
        logEvent(
            HomeKitEvent(
                timestamp: Date(),
                type: .characteristicUpdated,
                accessoryName: accessory.name,
                roomName: room,
                serviceName: service.name,
                characteristicName: characteristic.localizedDescription,
                value: value
            ))
    }
}
