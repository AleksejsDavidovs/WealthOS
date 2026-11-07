import SwiftUI

@main struct WealthOSApp: App {
    @State private var appModel = AppModel()
    @State private var lockManager = AppLockManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(lockManager)
        }
    }
}
