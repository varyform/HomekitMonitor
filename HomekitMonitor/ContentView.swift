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

#Preview {
    ContentView()
}
