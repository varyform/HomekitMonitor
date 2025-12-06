//
//  HomeKitManager.swift
//  HomekitMonitor
//
//  Created by Oleh Khomey on 06.12.2025.
//

import Combine
import Foundation
import HomeKit

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

    init(pattern: String) {
        self.id = UUID()
        self.pattern = pattern
        self.lastMatch = nil
        self.matchCount = 0
    }
}

class HomeKitManager: NSObject, ObservableObject {
    private let homeManager = HMHomeManager()

    @Published var homes: [HMHome] = []
    @Published var eventLog: [LogEntry] = []
    @Published var subscriptions: [Subscription] = []

    override init() {
        super.init()
        homeManager.delegate = self
        loadSubscriptions()
        logEvent("HomeKitManager initialized")
    }

    private func logEvent(_ message: String) {
        let timestamp = Date()
        let timestampStr = ISO8601DateFormatter().string(from: timestamp)
        let logMessage = "[\(timestampStr)] \(message)"
        print(logMessage)

        let entry = LogEntry(timestamp: timestamp, message: logMessage, rawEvent: message)

        DispatchQueue.main.async {
            self.eventLog.append(entry)
            self.checkSubscriptions(for: message, at: timestamp)
        }
    }

    func addSubscription(pattern: String) {
        let subscription = Subscription(pattern: pattern)
        DispatchQueue.main.async {
            self.subscriptions.append(subscription)
            self.saveSubscriptions()
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
                saveSubscriptions()
            }
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

    private func setupAccessoryDelegates(for home: HMHome) {
        for accessory in home.accessories {
            accessory.delegate = self
            logEvent("Registered delegate for accessory: \(accessory.name)")

            for service in accessory.services {
                logEvent("Service: \(service.name) (\(service.serviceType)) on \(accessory.name)")

                for characteristic in service.characteristics {
                    logEvent(
                        "Characteristic: \(characteristic.localizedDescription) on \(service.name)")
                    characteristic.enableNotification(true) { error in
                        if let error = error {
                            self.logEvent(
                                "Failed to enable notifications for \(characteristic.localizedDescription): \(error.localizedDescription)"
                            )
                        } else {
                            self.logEvent(
                                "Enabled notifications for \(characteristic.localizedDescription)")
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
        logEvent("Accessory added: \(accessory.name) to home: \(home.name)")
        accessory.delegate = self
        setupAccessoryDelegates(for: home)
    }

    func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        logEvent("Accessory removed: \(accessory.name) from home: \(home.name)")
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
        logEvent("Accessory name updated: \(accessory.name)")
    }

    func accessory(_ accessory: HMAccessory, didUpdateNameFor service: HMService) {
        logEvent("Service name updated: \(service.name) on accessory: \(accessory.name)")
    }

    func accessory(_ accessory: HMAccessory, didUpdateAssociatedServiceTypeFor service: HMService) {
        logEvent("Service type updated for: \(service.name) on accessory: \(accessory.name)")
    }

    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        logEvent("Services updated for accessory: \(accessory.name)")
    }

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let status = accessory.isReachable ? "reachable" : "unreachable"
        logEvent("Accessory \(accessory.name) is now \(status)")
    }

    func accessory(
        _ accessory: HMAccessory, service: HMService,
        didUpdateValueFor characteristic: HMCharacteristic
    ) {
        let value = characteristic.value ?? "nil"
        logEvent(
            "Characteristic updated: \(characteristic.localizedDescription) = \(value) on service: \(service.name) of accessory: \(accessory.name)"
        )
    }
}
