//
//  EditSubscriptionView.swift
//  HomekitMonitor
//
//  Created by Oleh Khomey on 07.12.2025.
//

import SwiftUI
import CodeEditor

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
                Text("Accessory: \(subscription.accessoryName)")
                    .font(.headline)
                Text("Characteristic: \(subscription.characteristicName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 10)

                Text("MQTT Topic")
                    .font(.caption)
                TextField("e.g., sensors/temperature", text: $mqttTopic)
                    .textFieldStyle(.roundedBorder)

                Text("MQTT Payload (use {{value}} for interpolation)")
                    .font(.caption)
                    .padding(.top, 10)
                CodeEditor(
                    source: $mqttPayload,
                    language: .json,
                    theme: CodeEditor.ThemeName(rawValue: "atom-one-dark")
                )

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
