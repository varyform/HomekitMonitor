//
//  ContentView.swift
//  HomekitMonitor
//
//  Created by Oleh Khomey on 06.12.2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var homeKitManager = HomeKitManager()

    var body: some View {
        VStack {
            Text("HomeKit Event Monitor")
                .font(.largeTitle)
                .padding()

            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(homeKitManager.eventLog.enumerated()), id: \.offset) {
                            index, event in
                            Text(event)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .onChange(of: homeKitManager.eventLog.count) {
                        if let lastIndex = homeKitManager.eventLog.indices.last {
                            withAnimation {
                                proxy.scrollTo(lastIndex, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
