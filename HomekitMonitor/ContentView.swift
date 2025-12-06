//
//  ContentView.swift
//  HomekitMonitor
//
//  Created by Oleh Khomey on 06.12.2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var homeKitManager = HomeKitManager()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            EventLogView(homeKitManager: homeKitManager)
                .tabItem {
                    Label("Events", systemImage: "list.bullet")
                }
                .tag(0)

            SubscriptionsView(homeKitManager: homeKitManager)
                .tabItem {
                    Label("Subscriptions", systemImage: "star")
                }
                .tag(1)

            MQTTConfigView(homeKitManager: homeKitManager)
                .tabItem {
                    Label("MQTT", systemImage: "network")
                }
                .tag(2)
        }
    }
}

struct EventLogView: View {
    @ObservedObject var homeKitManager: HomeKitManager

    var body: some View {
        VStack {
            Text("HomeKit Event Monitor")
                .font(.largeTitle)
                .padding()

            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(homeKitManager.eventLog) { entry in
                            HStack(spacing: 8) {
                                Button(action: {
                                    homeKitManager.addSubscription(pattern: entry.rawEvent)
                                }) {
                                    Image(systemName: "plus.circle")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)

                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .onChange(of: homeKitManager.eventLog.count) { _ in
                        if let lastEntry = homeKitManager.eventLog.last {
                            withAnimation {
                                proxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}

struct SubscriptionsView: View {
    @ObservedObject var homeKitManager: HomeKitManager
    @State private var newPattern = ""
    @State private var editingSubscription: Subscription?

    var body: some View {
        VStack {
            Text("Subscriptions")
                .font(.largeTitle)
                .padding()

            HStack {
                TextField("Enter pattern to watch...", text: $newPattern)
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
                    if !newPattern.isEmpty {
                        homeKitManager.addSubscription(pattern: newPattern)
                        newPattern = ""
                    }
                }
            }
            .padding(.horizontal)

            List {
                ForEach(homeKitManager.subscriptions) { subscription in
                    SubscriptionRow(subscription: subscription)
                        .onTapGesture {
                            editingSubscription = subscription
                        }
                        .contextMenu {
                            Button("Edit MQTT") {
                                editingSubscription = subscription
                            }
                            Button("Delete", role: .destructive) {
                                homeKitManager.removeSubscription(id: subscription.id)
                            }
                        }
                }
            }
        }
        .sheet(item: $editingSubscription) { subscription in
            EditSubscriptionView(
                homeKitManager: homeKitManager,
                subscription: subscription,
                isPresented: $editingSubscription
            )
        }
    }
}

struct SubscriptionRow: View {
    let subscription: Subscription
    @State private var isHighlighted = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(subscription.pattern)
                    .font(.headline)

                HStack {
                    Text("Matches: \(subscription.matchCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let lastMatch = subscription.lastMatch {
                        Text("Last: \(formatDate(lastMatch))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if isHighlighted {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
        .background(isHighlighted ? Color.orange.opacity(0.2) : Color.clear)
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        .onChange(of: subscription.lastMatch) { newValue in
            if newValue != nil {
                isHighlighted = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isHighlighted = false
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct EditSubscriptionView: View {
    @ObservedObject var homeKitManager: HomeKitManager
    let subscription: Subscription
    @Binding var isPresented: Subscription?

    @State private var mqttTopic: String
    @State private var mqttPayload: String

    init(
        homeKitManager: HomeKitManager, subscription: Subscription,
        isPresented: Binding<Subscription?>
    ) {
        self.homeKitManager = homeKitManager
        self.subscription = subscription
        self._isPresented = isPresented
        self._mqttTopic = State(initialValue: subscription.mqttTopic)
        self._mqttPayload = State(initialValue: subscription.mqttPayload)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Subscription")
                .font(.title)
                .padding()

            VStack(alignment: .leading) {
                Text("Pattern: \(subscription.pattern)")
                    .font(.headline)
                    .padding(.bottom, 10)

                Text("MQTT Topic")
                    .font(.caption)
                TextField("e.g., sensors/temperature", text: $mqttTopic)
                    .textFieldStyle(.roundedBorder)

                Text("MQTT Payload (use {{value}} for interpolation)")
                    .font(.caption)
                    .padding(.top, 10)
                TextEditor(text: $mqttPayload)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                    .border(Color.gray.opacity(0.3))
                    .disableAutocorrection(true)
                    #if os(macOS)
                        .onAppear {
                            NSTextView.appearance().automaticQuoteSubstitutionEnabled = false
                        }
                    #endif

                Text("Example: {\"state\": \"{{value}}\", \"device\": \"sensor1\"}")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()

            HStack {
                Button("Cancel") {
                    isPresented = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    homeKitManager.updateSubscription(
                        id: subscription.id,
                        mqttTopic: mqttTopic,
                        mqttPayload: mqttPayload
                    )
                    isPresented = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }
}

struct MQTTConfigView: View {
    @ObservedObject var homeKitManager: HomeKitManager

    var body: some View {
        VStack {
            Text("MQTT Configuration")
                .font(.largeTitle)
                .padding()

            HStack {
                Circle()
                    .fill(homeKitManager.mqttConnected ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(homeKitManager.mqttConnected ? "Connected" : "Disconnected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 10)

            Form {
                Section(header: Text("Broker Settings")) {
                    HStack {
                        Text("Server:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("localhost", text: $homeKitManager.mqttConfig.server)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Port:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("1883", value: $homeKitManager.mqttConfig.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Username:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("Optional", text: $homeKitManager.mqttConfig.username)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Password:")
                            .frame(width: 100, alignment: .trailing)
                        SecureField("Optional", text: $homeKitManager.mqttConfig.password)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Topic Prefix:")
                            .frame(width: 100, alignment: .trailing)
                        TextField("homekit", text: $homeKitManager.mqttConfig.prefix)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding()

            HStack(spacing: 15) {
                Button("Save Configuration") {
                    homeKitManager.saveMQTTConfig()
                }

                Button("Reconnect") {
                    homeKitManager.reconnectMQTT()
                }
                .disabled(!homeKitManager.mqttConnected)

                Button("Disconnect") {
                    homeKitManager.disconnectMQTT()
                }
                .disabled(!homeKitManager.mqttConnected)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
