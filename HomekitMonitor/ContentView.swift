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
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                homeKitManager.removeSubscription(id: subscription.id)
                            }
                        }
                }
            }
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

#Preview {
    ContentView()
}
