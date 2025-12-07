//
//  MQTTConfigView.swift
//  HomekitMonitor
//
//  Created by Oleh Khomey on 07.12.2025.
//

import SwiftUI

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
