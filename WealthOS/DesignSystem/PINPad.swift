import SwiftUI

/// Visual state of the PIN pad after a full entry.
enum PINPadFeedback: Equatable {
    case idle, error, success
}

/// Fixed dark palette: security surfaces stay graphite + turquoise regardless of the
/// app's light/dark setting, like the lock screen they sit on.
enum PINPadStyle {
    static let turquoise = Color(red: 0.20, green: 0.78, blue: 0.62)
    static let errorRed = Color(red: 1.0, green: 0.45, blue: 0.43)
    static let graphiteTop = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let graphiteBottom = Color(red: 0.035, green: 0.04, blue: 0.05)
}

struct PINPadBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [PINPadStyle.graphiteTop, PINPadStyle.graphiteBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [PINPadStyle.turquoise.opacity(0.20), .clear], center: .top, startRadius: 0, endRadius: 440)
        }
        .ignoresSafeArea()
    }
}

/// Six indicator dots. Only the *count* of digits ever reaches this view — never the digits.
struct PINDotsView: View {
    let filled: Int
    let length: Int
    let feedback: PINPadFeedback
    let shakeTrigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<length, id: \.self) { index in
                let isFilled = index < filled
                Circle()
                    .fill(isFilled ? dotColor : .clear)
                    .overlay { Circle().strokeBorder(isFilled ? dotColor : .white.opacity(0.35), lineWidth: 1.5) }
                    .frame(width: 14, height: 14)
                    .scaleEffect(isFilled ? (feedback == .success ? 1.25 : 1) : 0.85)
                    .shadow(color: feedback == .success ? PINPadStyle.turquoise.opacity(0.8) : .clear, radius: 6)
                    .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: isFilled)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55), value: feedback)
        .keyframeAnimator(initialValue: 0.0, trigger: shakeTrigger) { [reduceMotion] content, offset in
            content.offset(x: reduceMotion ? 0 : offset)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-14, duration: 0.06)
                LinearKeyframe(12, duration: 0.08)
                LinearKeyframe(-8, duration: 0.08)
                LinearKeyframe(5, duration: 0.07)
                SpringKeyframe(0, duration: 0.15)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN")
        .accessibilityValue("\(filled) of \(length) digits entered")
    }

    private var dotColor: Color {
        feedback == .error ? PINPadStyle.errorRed : PINPadStyle.turquoise
    }
}

/// 3×4 numeric keypad drawn in SwiftUI — no system keyboard, so no autofill, predictive
/// text or keyboard caches ever see the PIN. Rounded-square keys keep it visually distinct
/// from Apple's device-passcode screen.
struct PINKeypad: View {
    struct LeadingKey {
        let symbol: String
        let label: String
        let action: () -> Void
    }

    let isEnabled: Bool
    let canDelete: Bool
    var leadingKey: LeadingKey?
    let onDigit: (Int) -> Void
    let onDelete: () -> Void

    @ScaledMetric(relativeTo: .title) private var scaledKeyHeight: CGFloat = 64
    private var keyHeight: CGFloat { min(scaledKeyHeight, 88) }
    private let rows = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { digitKey($0) }
                }
            }
            GridRow {
                if let leadingKey {
                    Button(action: leadingKey.action) {
                        Image(systemName: leadingKey.symbol).font(.title2)
                    }
                    .buttonStyle(PINKeyStyle(height: keyHeight, isSecondary: true))
                    .accessibilityLabel(leadingKey.label)
                } else {
                    Color.clear.frame(height: keyHeight).accessibilityHidden(true)
                }
                digitKey(0)
                Button(action: onDelete) {
                    Image(systemName: "delete.backward").font(.title2)
                }
                .buttonStyle(PINKeyStyle(height: keyHeight, isSecondary: true))
                .disabled(!isEnabled || !canDelete)
                .accessibilityLabel("Delete")
            }
        }
        .padding(.horizontal, 32)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func digitKey(_ digit: Int) -> some View {
        Button { onDigit(digit) } label: {
            Text(verbatim: "\(digit)")
                .font(.title.weight(.medium))
                .fontDesign(.rounded)
                .monospacedDigit()
        }
        .buttonStyle(PINKeyStyle(height: keyHeight))
        .disabled(!isEnabled)
        .accessibilityLabel(Text(verbatim: "\(digit)"))
    }
}

struct PINKeyStyle: ButtonStyle {
    let height: CGFloat
    var isSecondary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.3))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                shape
                    .fill(.white.opacity(isSecondary ? (configuration.isPressed ? 0.10 : 0) : (configuration.isPressed ? 0.20 : 0.07)))
                    .overlay {
                        shape.strokeBorder(configuration.isPressed ? PINPadStyle.turquoise.opacity(0.7)
                                                                    : .white.opacity(isSecondary ? 0 : 0.08), lineWidth: 1)
                    }
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Full-screen PIN layout shared by unlock and setup. Holds no PIN state itself; callers
/// own the digits and clear them as soon as they're checked or the screen goes away.
struct PINPadScreen<Footer: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let filled: Int
    let feedback: PINPadFeedback
    let shakeTrigger: Int
    let message: String?
    let messageIsError: Bool
    let keypadEnabled: Bool
    var leadingKey: PINKeypad.LeadingKey?
    let onDigit: (Int) -> Void
    let onDelete: () -> Void
    @ViewBuilder var footer: Footer

    var body: some View {
        ZStack {
            PINPadBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(PINPadStyle.turquoise)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(PINPadStyle.turquoise.opacity(0.12)))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 6)
                PINDotsView(filled: filled, length: AppPINManager.pinLength, feedback: feedback, shakeTrigger: shakeTrigger)
                    .padding(.top, 28)
                Text(message ?? " ")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(messageIsError ? PINPadStyle.errorRed : .white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 38, alignment: .top)
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
                    .accessibilityHidden(message == nil)
                Spacer(minLength: 12)
                PINKeypad(isEnabled: keypadEnabled, canDelete: filled > 0, leadingKey: leadingKey,
                          onDigit: onDigit, onDelete: onDelete)
                footer
                    .padding(.top, 18)
                    .padding(.bottom, 16)
            }
        }
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(trigger: filled) { old, new in new > old ? .selection : nil }
        .sensoryFeedback(.error, trigger: shakeTrigger)
        .sensoryFeedback(trigger: feedback) { _, new in new == .success ? .success : nil }
    }
}

#Preview("PIN pad") {
    PINPadScreen(icon: "lock.fill", title: "Enter WealthOS PIN",
                 subtitle: "Your 6-digit app PIN — not your iPhone passcode.",
                 filled: 3, feedback: .idle, shakeTrigger: 0,
                 message: "Incorrect PIN · 2 attempts before a delay", messageIsError: true,
                 keypadEnabled: true,
                 leadingKey: .init(symbol: "faceid", label: "Use Face ID", action: {}),
                 onDigit: { _ in }, onDelete: {}) {
        Label("Forgot PIN? Use iPhone Passcode", systemImage: "key.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PINPadStyle.turquoise)
    }
}

extension TimeInterval {
    /// "0:27", "4:59" — for lockout countdowns.
    var countdownText: String {
        Duration.seconds(Int(self.rounded(.up))).formatted(.time(pattern: .minuteSecond))
    }
}
