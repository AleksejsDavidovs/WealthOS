import SwiftUI

enum Theme {
    static let cornerRadius: CGFloat = 22
    static let smallCornerRadius: CGFloat = 14
    static let spacing: CGFloat = 16
    static let cardPadding: CGFloat = 18

    // Semantic colors adapt to the appearance so text keeps ≥ 4.5:1 contrast on
    // both white (light) and near-black (dark) cards.
    static let accent = Color(light: Color(red: 0.0, green: 0.52, blue: 0.42), dark: Color(red: 0.20, green: 0.78, blue: 0.62))
    /// Fill for prominent buttons; white labels stay readable in both appearances.
    static let accentFill = Color(red: 0.0, green: 0.50, blue: 0.42)
    static let positive = Color(light: Color(red: 0.0, green: 0.50, blue: 0.22), dark: Color(red: 0.25, green: 0.82, blue: 0.48))
    static let negative = Color(light: Color(red: 0.80, green: 0.10, blue: 0.12), dark: Color(red: 1.0, green: 0.45, blue: 0.43))
    static let warning = Color(light: Color(red: 0.70, green: 0.35, blue: 0.0), dark: Color(red: 1.0, green: 0.68, blue: 0.25))
    static let projection = Color(light: Color(red: 0.45, green: 0.22, blue: 0.80), dark: Color(red: 0.72, green: 0.55, blue: 1.0))

    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.07, green: 0.36, blue: 0.33), Color(red: 0.05, green: 0.16, blue: 0.27)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let palette: [String] = ["blue", "green", "mint", "teal", "cyan", "indigo", "purple", "pink", "red", "orange", "yellow", "brown", "gray"]

    static func color(named name: String) -> Color {
        switch name {
        case "blue": .blue
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "brown": .brown
        default: .gray
        }
    }

    static func signColor(_ value: Decimal) -> Color {
        value > 0 ? positive : (value < 0 ? negative : .secondary)
    }
}

// MARK: - Card styles

struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.cardPadding
    /// Off for cards placed in List rows: a row clips the soft shadow into a visible straight edge.
    var shadow = true
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.05 : 0.0), .clear],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(colorScheme == .dark ? 0.06 : 0), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark || !shadow ? 0 : 0.05), radius: 10, y: 4)
            }
    }
}

extension View {
    func card(padding: CGFloat = Theme.cardPadding, shadow: Bool = true) -> some View {
        modifier(CardModifier(padding: padding, shadow: shadow))
    }

    /// Liquid Glass on iOS 26+, material fallback on earlier versions.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = Theme.cornerRadius, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        } else {
            self.background(tint.map { AnyShapeStyle($0.gradient) } ?? AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
    }

    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(Theme.accentFill)
        } else {
            self.buttonStyle(.borderedProminent).tint(Theme.accentFill)
        }
    }

    func screenBackground() -> some View {
        self.background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    /// Fixed design size that still follows the user's text size setting.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .bold, design: Font.Design = .rounded,
                    relativeTo style: Font.TextStyle = .largeTitle) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design, style: style))
    }
}

struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension Color {
    /// Appearance-dependent color backed by a dynamic UIColor.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - Skeleton shimmer

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width)
                    }
                    .mask(content.redacted(reason: .placeholder))
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
            .accessibilityLabel("Loading")
    }
}

extension View {
    func skeleton(_ active: Bool) -> some View {
        Group {
            if active { self.modifier(ShimmerModifier()) } else { self }
        }
    }
}
