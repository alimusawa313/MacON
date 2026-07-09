//
//  MacONApp.swift
//  MacON
//
//  A local Bitbucket runner POOL for this Mac: manages many self-hosted runner
//  agents (one per repo/workspace), streams their logs, and cleans up caches.
//

import SwiftUI
import MaconKit

@main
struct MacONApp: App {
    @StateObject private var pool = RunnerPool()
    @StateObject private var pipelines = PipelinePool()
    @StateObject private var companion = CompanionManager()
    @StateObject private var theme = ThemeManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pool)
                .environmentObject(pipelines)
                .environmentObject(companion)
                .environmentObject(theme)
                .tint(Brand.blue)
                .task {
                    // Bring the companion server back up if it was on last time.
                    if companion.startsAtLaunch && !companion.isRunning {
                        companion.start(runnerName: ProcessInfo.processInfo.hostName,
                                        runners: { pipelines.pipelines })
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)

        // Quick control from the menu bar.
        MenuBarExtra("MacON", systemImage: menuIcon) {
            Text("\(pipelines.watchingCount) pipelines watching")
            Text("\(pool.activeCount)/\(pool.agents.count) runners active")
            Divider()
            Button("Watch All Pipelines") { pipelines.startAll() }
                .disabled(pipelines.pipelines.isEmpty)
            Button("Stop All Pipelines") { pipelines.stopAll() }
                .disabled(pipelines.watchingCount == 0)
            Divider()
            Button("Start All Runners") { pool.startAll() }
                .disabled(pool.agents.isEmpty)
            Button("Stop All Runners") { pool.stopAll() }
                .disabled(!pool.anyActive)
            Button("Clean Caches") { pool.cleanCaches() }
                .disabled(pool.anyActive || pool.isCleaningCaches)
            Divider()
            Button("Quit MacON") { NSApplication.shared.terminate(nil) }
        }
    }

    private var menuIcon: String {
        (pool.anyActive || pipelines.watchingCount > 0) ? "bolt.fill" : "bolt.slash"
    }
}
