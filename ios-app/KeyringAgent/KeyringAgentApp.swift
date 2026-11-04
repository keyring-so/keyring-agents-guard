import Foundation
import SwiftUI

@main
struct KeyringAgentApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PendingListView()
                .environmentObject(model)
                .onOpenURL { model.handle(url: $0) }
                .task {
                    await model.refresh()
                    // Debug/demo hook: SIMCTL_CHILD_OPEN_URL=keyring-agent://approve?…&id=…
                    if let raw = ProcessInfo.processInfo.environment["OPEN_URL"],
                       let url = URL(string: raw) {
                        model.handle(url: url)
                    }
                    model.startPolling()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.refresh() }
                        model.startPolling()
                    } else {
                        model.stopPolling()
                    }
                }
        }
    }
}
