import SwiftUI
import SwiftData

/// Top-level container: chooses onboarding vs. main tabs, and layers the app lock
/// and the app-switcher privacy cover above everything.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppLockManager.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var overlay = SecureOverlayWindow()

    var body: some View {
        Group {
            if let container = app.activeContainer {
                Group {
                    if hasCompletedOnboarding || app.isDemoMode || app.storeHadDataAtLaunch {
                        MainTabView()
                    } else {
                        OnboardingView()
                    }
                }
                .modelContainer(container)
                .id(app.isDemoMode)
            } else {
                StoreErrorView(message: app.loadError ?? "Unknown error.")
            }
        }
        .overlay {
            // Defense in depth for the first frames of a cold launch, before the overlay
            // window is attached. No sheet can be open yet, so an in-window cover suffices
            // here; once attached, the overlay window covers everything including sheets.
            if lock.isLocked { PrivacyCoverView() }
        }
        .background(WindowAccessor { window in
            overlay.attach(using: window)
            AppAppearanceModifier.apply(AppearanceMode.resolve(UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? ""))
            updateOverlay()
        })
        .tint(Theme.accent)
        .appAppearance()
        .onAppear {
            // Repair a missing onboarding flag when real data already exists.
            if app.storeHadDataAtLaunch && !hasCompletedOnboarding && !app.isDemoMode { hasCompletedOnboarding = true }
        }
        .task {
            // Cold launch straight into .active fires no onChange; otherwise onChange handles it.
            if scenePhase == .active { lock.authenticateAutomatically() }
        }
        .onChange(of: lock.isLocked) { _, _ in updateOverlay() }
        .onChange(of: lock.showPINEntry) { _, _ in updateOverlay() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, let container = app.persistentContainer {
                // Flush autosave-pending edits before iOS may suspend or terminate the app.
                Persistence.flush(container.mainContext)
            }
            if phase == .background {
                lock.lockIfEnabled()
                BackupService.cleanTemporaryExports()
            }
            if phase == .active {
                lock.authenticateAutomatically()
            }
            updateOverlay()
        }
    }

    /// Single source of truth for what the secure overlay window shows. Covers both the
    /// lock screen and the app-switcher privacy cover, so neither can be bypassed by a sheet
    /// left open underneath — the overlay sits in its own window above all UIKit presentations.
    private func updateOverlay() {
        if lock.isLocked {
            overlay.show { LockScreenView().environment(lock) }
        } else if scenePhase != .active {
            overlay.show { PrivacyCoverView() }
        } else {
            overlay.hide()
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.baseCurrency) private var baseCurrency = "EUR"

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Transactions", systemImage: "list.bullet.rectangle.portrait.fill", value: AppTab.transactions) {
                TransactionsView()
            }
            Tab("Investments", systemImage: "chart.pie.fill", value: AppTab.investments) {
                InvestmentsView()
            }
            Tab("Simulator", systemImage: "wand.and.sparkles", value: AppTab.simulator) {
                SimulatorView()
            }
            Tab("Goals", systemImage: "target", value: AppTab.goals) {
                GoalsView()
            }
        }
        .sheet(item: $app.quickAddRequest) { TransactionEditorView(request: $0) }
        .task {
            DataMaintenance.run(context: context, baseCurrency: baseCurrency)
            autoSyncIntegrations()
            await autoRefreshMarketData()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                DataMaintenance.run(context: context, baseCurrency: baseCurrency)
                Task { await autoRefreshMarketData() }
                autoSyncIntegrations()
            }
        }
    }

    @Environment(MarketDataService.self) private var marketData
    @Environment(Trading212Service.self) private var trading212
    @Environment(BinanceService.self) private var binance
    @AppStorage(SettingsKey.marketAutoRefresh) private var marketAutoRefresh = true

    /// Only when the cached snapshot is stale (15 min) and never against demo data. Each
    /// service refuses overlapping runs and backs off after failures, so rapid
    /// foreground/background switches cause at most one request set per provider.
    private func autoSyncIntegrations() {
        // Credentials are "when unlocked" Keychain items: re-read them now that the app is active.
        trading212.reloadConnectionState()
        binance.reloadConnectionState()
        guard !app.isDemoMode, let real = app.persistentContainer?.mainContext else { return }
        if trading212.isConnected { Task { await trading212.syncIfStale(context: real) } }
        if binance.isConnected { Task { await binance.syncIfStale(context: real) } }
    }

    /// Respects each provider's cache TTL, so frequent app switches don't cause requests.
    private func autoRefreshMarketData() async {
        guard marketData.isEnabled, marketAutoRefresh else { return }
        await marketData.refresh(context: context, baseCurrency: baseCurrency)
    }
}

/// Inline Quick Add row shown on Home directly under the net-worth card. It is part of
/// the scroll content, so it never covers the chart, other cards, or the tab bar.
struct QuickActionsRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Button { request(.expense) } label: {
                Label("Expense", systemImage: "minus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentFill)

            Button { request(.income) } label: {
                Label("Income", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.positive)

            Button { request(.transfer) } label: {
                Label("Transfer", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.indigo)
        }
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .buttonBorderShape(.capsule)
        .sensoryFeedback(.impact(weight: .medium), trigger: app.quickAddRequest?.id)
    }

    private func request(_ kind: TransactionKind) {
        app.quickAddRequest = TransactionEditorRequest(kind: kind)
    }
}

/// Toolbar "+" menu so Quick Add stays one tap away after scrolling past the inline row.
struct QuickAddToolbarMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Button { app.quickAddRequest = .init(kind: .expense) } label: { Label("Expense", systemImage: TransactionKind.expense.symbol) }
            Button { app.quickAddRequest = .init(kind: .income) } label: { Label("Income", systemImage: TransactionKind.income.symbol) }
            Button { app.quickAddRequest = .init(kind: .transfer) } label: { Label("Transfer", systemImage: TransactionKind.transfer.symbol) }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            app.quickAddRequest = .init(kind: .expense)
        }
        .accessibilityLabel("Add transaction")
    }
}

struct LockScreenView: View {
    @Environment(AppLockManager.self) private var lock

    var body: some View {
        ZStack {
            Theme.heroGradient.ignoresSafeArea()
            if lock.showPINEntry {
                PINEntryView()
                    .transition(.opacity)
            } else {
                VStack(spacing: 24) {
                    Spacer()
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(.white)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("WealthOS is Locked").font(.title2.bold()).foregroundStyle(.white)
                        Text("Your financial data stays on this iPhone.").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    }
                    if let message = lock.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Spacer()
                    Button {
                        Task { await lock.authenticate() }
                    } label: {
                        Label("Unlock with \(lock.biometryName)", systemImage: lock.biometrySymbol)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .prominentButtonStyle()
                    .controlSize(.large)
                    .disabled(lock.isAuthenticating)
                    .padding(.horizontal, 32)

                    if lock.isPINEnabled {
                        Button { lock.requestPINEntry() } label: {
                            Label("Enter WealthOS PIN", systemImage: "circle.grid.3x3.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.bottom, 40)
                    } else {
                        // Without an app PIN the only fallback is Apple's passcode sheet; say so.
                        Text("Falls back to your iPhone passcode. Set up a WealthOS PIN in Settings to use it instead.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .padding(.bottom, 32)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lock.showPINEntry)
    }
}

/// Full-screen WealthOS PIN unlock. Rendered inside `SecureOverlayWindow` (as part of
/// `LockScreenView`), so no sheet or financial content can appear above or behind it.
/// The digits exist only in `digits` and are cleared after every check and on disappear.
struct PINEntryView: View {
    @Environment(AppLockManager.self) private var lock
    @State private var digits = ""
    @State private var feedback: PINPadFeedback = .idle
    @State private var shakeTrigger = 0
    @State private var message: String?

    private static let disabledMessage = "PIN disabled after too many attempts. Use Face ID or your iPhone passcode, then set a new PIN in Settings."

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lockout = lock.isPINUsable ? lock.pinLockoutRemaining(now: context.date) : nil
            PINPadScreen(
                icon: feedback == .success ? "lock.open.fill" : "lock.fill",
                title: "Enter WealthOS PIN",
                subtitle: "Your 6-digit app PIN — not your iPhone passcode.",
                filled: digits.count,
                feedback: feedback,
                shakeTrigger: shakeTrigger,
                message: statusMessage(lockout: lockout),
                messageIsError: !lock.isPINUsable || lockout != nil || feedback == .error,
                keypadEnabled: lock.isPINUsable && lockout == nil && !lock.isVerifyingPIN && feedback != .success,
                leadingKey: lock.canUseBiometrics
                    ? .init(symbol: lock.biometrySymbol, label: "Use \(lock.biometryName)", action: useBiometrics)
                    : nil,
                onDigit: append,
                onDelete: { if !digits.isEmpty { digits.removeLast() } }
            ) {
                VStack(spacing: 4) {
                    Button(action: useDevicePasscode) {
                        Label("Forgot PIN? Use iPhone Passcode", systemImage: "key.fill")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(PINPadStyle.turquoise)
                    .disabled(lock.isAuthenticating || lock.isVerifyingPIN)
                    .accessibilityHint("Opens Apple's secure passcode screen. Your WealthOS PIN is not changed.")
                    Text("Opens Apple's secure iPhone passcode screen.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .accessibilityHidden(true)
                }
            }
        }
        .onDisappear(perform: clear)
    }

    private func statusMessage(lockout: TimeInterval?) -> String? {
        if !lock.isPINUsable { return Self.disabledMessage }
        if let lockout { return "Too many attempts. Try again in \(lockout.countdownText)." }
        return message
    }

    private func append(_ digit: Int) {
        guard digits.count < AppPINManager.pinLength else { return }
        if feedback == .error { feedback = .idle; message = nil }
        digits.append(String(digit))
        if digits.count == AppPINManager.pinLength { submit() }
    }

    private func submit() {
        let candidate = digits
        Task {
            guard let result = await lock.verifyPIN(candidate) else { return }
            switch result {
            case .success:
                feedback = .success   // the overlay fades out over this state
                message = nil
            case .incorrect(let remaining):
                reject(remaining > 0
                       ? "Incorrect PIN · \(remaining) attempt\(remaining == 1 ? "" : "s") before a delay"
                       : "Incorrect PIN")
            case .lockedOut, .disabled:
                reject(nil)            // the countdown / disabled text takes over
            case .unavailable:
                reject("PIN can't be checked right now. Use \(lock.biometryName) or your iPhone passcode.")
            case .notEnrolled:
                clear()
                lock.cancelPINEntry()
            }
        }
    }

    private func reject(_ text: String?) {
        feedback = .error
        message = text
        shakeTrigger += 1
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            digits = ""
        }
    }

    private func useBiometrics() {
        clear()
        lock.cancelPINEntry()
        Task { await lock.authenticate() }
    }

    private func useDevicePasscode() {
        clear()
        Task { await lock.authenticateWithDevicePasscode() }
    }

    private func clear() {
        digits = ""
        feedback = .idle
        message = nil
    }
}

struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                Text("WealthOS").font(.title2.bold())
            }
        }
        .accessibilityHidden(true)
    }
}

struct StoreErrorView: View {
    let message: String
    var body: some View {
        ContentUnavailableView("Data Unavailable", systemImage: "externaldrive.badge.exclamationmark",
                               description: Text(message))
    }
}
