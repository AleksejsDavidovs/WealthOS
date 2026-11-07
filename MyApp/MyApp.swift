import SwiftUI

@main struct WealthOSApp: App {
    @State private var appModel = AppModel()
    @State private var lockManager = AppLockManager()
    @State private var marketData = MarketDataService()

    init() {
        // Online prices stay off until the user enables them; when enabled, refresh on open.
        UserDefaults.standard.register(defaults: [SettingsKey.marketAutoRefresh: true])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(lockManager)
                .environment(marketData)
        }
    }
}
