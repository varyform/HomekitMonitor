//
//  EventLogView.swift
//  HomekitMonitor
//
//  Created by Oleh Khomey on 07.12.2025.
//

import SwiftUI

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
                        ForEach(homeKitManager.eventLog) { event in
                            HStack(spacing: 8) {
                                if event.type == .characteristicUpdated,
                                    let accessory = event.accessoryName,
                                    let characteristic = event.characteristicName
                                {
                                    Button(action: {
                                        homeKitManager.addSubscription(
                                            accessoryName: accessory,
                                            characteristicName: characteristic
                                        )
                                    }) {
                                        Image(systemName: "plus.circle")
                                            .foregroundColor(.blue)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.clear)
                                }

                                Text(event.displayText)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .id(event.id)
                        }
                    }
                    .onChange(of: homeKitManager.eventLog.count) {
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
