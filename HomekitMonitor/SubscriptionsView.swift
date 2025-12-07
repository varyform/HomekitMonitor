//
//  SubscriptionsView.swift
//  HomekitMonitor
//
//  Created by Oleh Khomey on 07.12.2025.
//

import SwiftUI

struct SubscriptionsView: View {
    @ObservedObject var homeKitManager: HomeKitManager
    @State private var editingSubscription: Subscription?

    var body: some View {
        VStack {
            Text("Subscriptions")
                .font(.largeTitle)
                .padding()

            Text("Click + icon next to characteristic updates in Events tab to subscribe")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom)

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
                Text(subscription.accessoryName)
                    .font(.headline)

                Text(subscription.characteristicName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

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
        .onChange(of: subscription.lastMatch) {
            if subscription.lastMatch != nil {
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
