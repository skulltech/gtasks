import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run outside the .app bundle (e.g. `swift run`).
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct GTasksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth: AuthManager
    @StateObject private var store: TaskStore

    init() {
        let auth = AuthManager()
        let store = TaskStore(auth: auth)
        store.startAutoRefresh()
        _auth = StateObject(wrappedValue: auth)
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(auth: auth, store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
