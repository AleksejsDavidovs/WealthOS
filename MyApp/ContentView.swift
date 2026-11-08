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
            await autoRefreshMarketData()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                DataMaintenance.run(context: context, baseCurrency: baseCurrency)
                Task { await autoRefreshMarketData() }
            }
        }
    }

    @Environment(MarketDataService.self) private var marketData
    @AppStorage(SettingsKey.marketAutoRefresh) private var marketAutoRefresh = true

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
                        Button("Use PIN Instead") { lock.requestPINEntry() }
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.bottom, 40)
                    } else {
                        Color.clear.frame(height: 24)
                    }
                }
            }
        }
    }
}

/// Six-digit PIN fallback shown on the lock screen after repeated Face ID failures, or on
/// request. Hosted inside the same secure overlay window as `LockScreenView`, so it carries
/// the same guarantee of never being bypassable by an open sheet underneath.
struct PINEntryView: View {
    @Environment(AppLockManager.self) private var lock
    @State private var input = ""
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "number.circle.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
            Text("Enter Your PIN").font(.title2.bold()).foregroundStyle(.white)
            if lock.isPINUsable {
                PINDigitsField(value: $input, length: AppPINManager.pinLength, tint: .white) { submit() }
            }
            if let message = statusMessage ?? (lock.isPINUsable ? nil : Self.disabledMessage) {
                Text(message).font(.footnote)
                    .foregroundStyle(isError || !lock.isPINUsable ? .yellow : .white.opacity(0.85))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Spacer()
            Button {
                input = ""
                lock.cancelPINEntry()
                Task { await lock.authenticate() }
            } label: {
                Label("Use \(lock.biometryName) Instead", systemImage: lock.biometrySymbol)
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .prominentButtonStyle()
            .controlSize(.large)
            .disabled(lock.isAuthenticating)
            .padding(.horizontal, 32)

            // Recovery: the device passcode always works, so a forgotten PIN never locks
            // the owner out of their data.
            Button("Forgot PIN? Use Device Passcode") {
                input = ""
                Task { await lock.authenticateWithDevicePasscode() }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.85))
            .disabled(lock.isAuthenticating)
            .padding(.bottom, 32)
        }
        .onDisappear { input = "" }
    }

    private static let disabledMessage = "PIN disabled after too many attempts. Unlock with Face ID or your device passcode, then set a new PIN in Settings."

    private func submit() {
        let result = lock.verifyPIN(input)
        input = ""
        switch result {
        case .success:
            statusMessage = nil
            isError = false
        case .incorrect(let remaining):
            isError = true
            statusMessage = remaining > 0 ? "Incorrect PIN — \(remaining) attempt\(remaining == 1 ? "" : "s") left." : "Incorrect PIN."
        case .lockedOut(let retryAfter):
            isError = true
            statusMessage = "Too many attempts. Try again in \(Self.format(retryAfter))."
        case .disabled:
            isError = true
            statusMessage = Self.disabledMessage
        case .notEnrolled:
            isError = false
            statusMessage = nil
            lock.cancelPINEntry()
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        interval < 60 ? "\(Int(interval.rounded(.up))) sec" : "\(Int((interval / 60).rounded(.up))) min"
    }
}

/// A row of masked digit indicators backed by an invisible numeric `SecureField`, used for
/// both PIN entry and PIN creation. The PIN is held only in `value`, cleared by callers as
/// soon as it's been checked or submitted — never logged, never written to disk by this view.
struct PINDigitsField: View {
    @Binding var value: String
    let length: Int
    var tint: Color = .primary
    var onComplete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 16) {
                ForEach(0..<length, id: \.self) { i in
                    Circle()
                        .fill(i < value.count ? tint : tint.opacity(0.2))
                        .frame(width: 16, height: 16)
                }
            }
            SecureField("", text: Binding(get: { value }, set: { newValue in
                let digits = newValue.filter(\.isNumber)
                value = String(digits.prefix(length))
                if value.count == length { onComplete() }
            }))
            .keyboardType(.numberPad)
            .focused($focused)
            .opacity(0.02)
            .frame(width: 1, height: 1)
            .accessibilityLabel("PIN entry")
        }
        .onTapGesture { focused = true }
        .onAppear { focused = true }
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
