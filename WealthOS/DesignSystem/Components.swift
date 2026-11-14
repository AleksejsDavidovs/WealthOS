import SwiftUI

/// Formatted money with optional sign coloring and numeric transitions.
struct MoneyText: View {
    let amount: Decimal
    let code: String
    var showSign = false
    var colored = false
    var fractionDigits = 2

    var body: some View {
        Text(MoneyFormat.string(amount, code: code, showSign: showSign, fractionDigits: fractionDigits))
            .monospacedDigit()
            .foregroundStyle(colored ? Theme.signColor(amount) : Color.primary)
            .contentTransition(.numericText(value: amount.doubleValue))
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var symbol: String
    var tint: Color = .accentColor
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

struct Metric: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    var color: Color?
}

/// Evenly spaced label/value pairs used in cards and hero headers.
struct MetricRow: View {
    let metrics: [Metric]
    var onDark = false
    var valueFont: Font = .subheadline.weight(.semibold)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(onDark ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(metric.value)
                        .font(valueFont)
                        .monospacedDigit()
                        .foregroundStyle(metric.color ?? (onDark ? Color.white : Color.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ProgressRing: View {
    let progress: Double
    var color: Color = .accentColor
    var lineWidth: CGFloat = 10
    @State private var animatedProgress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(animatedProgress, 0), 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { update() }
        .onChange(of: progress) { _, _ in update() }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(progress.formatted(.percent.precision(.fractionLength(0)))))
    }

    private func update() {
        if reduceMotion { animatedProgress = progress } else {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8)) { animatedProgress = progress }
        }
    }
}

struct InfoBanner: View {
    let text: String
    var symbol = "info.circle.fill"
    var tint: Color = .blue

    var body: some View {
        Label {
            Text(text).font(.footnote).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }
}

/// Shown wherever live totals are used (Goals, Simulator, Accounts) when they aren't fully
/// confirmed, so a lower-bound valuation is never presented as a verified amount.
struct ValuationCompletenessBanner: View {
    let summary: NetWorthSummary
    /// What the warning refers to, e.g. "Goal funds".
    var subject = "These totals"

    var body: some View {
        if !summary.isComplete {
            InfoBanner(text: "Incomplete valuation — \(subject) only include confirmed amounts: "
                       + summary.completenessIssues.joined(separator: "; ") + ". See Investments for details.",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }
}

struct EmptyStateCard: View {
    let title: String
    let message: String
    let symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(Theme.accent)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .prominentButtonStyle()
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .card()
    }
}

/// Text input for money and quantities with live validation.
struct AmountField: View {
    let title: String
    @Binding var text: String
    var currencyCode: String?
    var validation: AmountValidation
    var prompt: String = "0.00"
    var allowNegative = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if let currencyCode {
                    Text(Currencies.symbol(for: currencyCode)).foregroundStyle(.secondary)
                }
                TextField(prompt, text: $text)
                    .keyboardType(allowNegative ? .numbersAndPunctuation : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 180)
                    .accessibilityLabel(title)
            }
            if let message = validation.message {
                Text(message).font(.caption).foregroundStyle(Theme.negative)
                    .accessibilityLabel("Error: \(message)")
            }
        }
    }
}

struct ColorSwatchPicker: View {
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Theme.palette, id: \.self) { name in
                    Circle()
                        .fill(Theme.color(named: name).gradient)
                        .frame(width: 30, height: 30)
                        .overlay {
                            if selection == name {
                                Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
                            }
                        }
                        .padding(4)
                        .onTapGesture { selection = name }
                        .accessibilityLabel(name.capitalized)
                        .accessibilityAddTraits(selection == name ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}

struct DemoBanner: View {
    var body: some View {
        Label("Demo mode · sample data, not saved", systemImage: "theatermasks.fill")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule(tint: .orange.opacity(0.35))
            .accessibilityAddTraits(.isStaticText)
    }
}

extension Date {
    var relativeDescription: String {
        formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

/// Applies the user's System / Light / Dark preference at the window level.
///
/// `preferredColorScheme` doesn't update sheets that are already presented, and switching
/// it back to `nil` (System) doesn't clear an earlier explicit choice. Setting UIKit's
/// `overrideUserInterfaceStyle` on the scene's windows updates the root view and every
/// presented sheet immediately, and `.unspecified` correctly follows the system again.
struct AppAppearanceModifier: ViewModifier {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.dark.rawValue

    func body(content: Content) -> some View {
        content
            .onAppear { Self.apply(AppearanceMode.resolve(appearance)) }
            .onChange(of: appearance) { _, newValue in Self.apply(AppearanceMode.resolve(newValue)) }
    }

    static func apply(_ mode: AppearanceMode) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = mode.interfaceStyle
            }
        }
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }

    /// Alert for a failed user-initiated save. Set the binding to the error message.
    func saveErrorAlert(_ message: Binding<String?>) -> some View {
        alert("Couldn't Save", isPresented: Binding(get: { message.wrappedValue != nil },
                                                    set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
