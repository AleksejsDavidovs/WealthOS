import SwiftUI
import SwiftData

/// Top-level container: chooses onboarding vs. main tabs, and layers the app lock
/// and the app-switcher privacy cover above everything.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppLockManager.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.dark.rawValue
    @AppStorage(SettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            if let container = app.activeContainer {
                Group {
                    if hasCompletedOnboarding || app.isDemoMode {
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

            if lock.isLocked {
                LockScreenView()
                    .transition(.opacity)
                    .zIndex(2)
            } else if scenePhase != .active {
                PrivacyCoverView()
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: lock.isLocked)
        .tint(Theme.accent)
        .preferredColorScheme(colorScheme)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                lock.lockIfEnabled()
                BackupService.cleanTemporaryExports()
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch AppearanceMode(rawValue: appearance) ?? .dark {
        case .system: nil
        case .light: .light
        case .dark: .dark
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
        .task { DataMaintenance.run(context: context, baseCurrency: baseCurrency) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { DataMaintenance.run(context: context, baseCurrency: baseCurrency) }
        }
    }
}

struct LockScreenView: View {
    @Environment(AppLockManager.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.heroGradient.ignoresSafeArea()
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
                .padding(.bottom, 40)
            }
        }
        .task {
            if scenePhase == .active { await lock.authenticate() }
        }
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
