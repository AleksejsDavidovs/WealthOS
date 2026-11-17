import SwiftUI

@main struct WealthOSApp: App {
    @State private var appModel = AppModel()
    @State private var lockManager = AppLockManager()
    @State private var marketData = MarketDataService()
    @State private var trading212 = Trading212Service.makeForApp()
    @State private var binance = BinanceService.makeForApp()
    @State private var banking = BankingService.makeForApp()

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
                .environment(trading212)
                .environment(binance)
                .environment(banking)
        }
    }
}
