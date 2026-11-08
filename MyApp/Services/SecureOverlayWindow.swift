import SwiftUI
import UIKit

/// A dedicated `UIWindow` placed above the app's key window at a higher window level.
///
/// SwiftUI's `.sheet`/`.fullScreenCover`/`.confirmationDialog` are presented as UIKit view
/// controllers on top of the *window* that hosts the presenting view, not above sibling
/// content drawn inside that same window's SwiftUI view tree. A ZStack-based lock screen is
/// therefore still a sibling of any open sheet inside the same window, and the OS always
/// draws a presented view controller above it — the sheet wins regardless of SwiftUI
/// z-ordering. Putting the lock screen in its own window at a higher `windowLevel` guarantees
/// it is painted (and receives touches) above every view controller presented in the main
/// window, no matter what is open underneath.
@MainActor
final class SecureOverlayWindow {
    private weak var mainWindow: UIWindow?
    private var overlayWindow: UIWindow?
    private var hosting: UIHostingController<AnyView>?

    /// Idempotent: call as often as needed, the window is created once per scene.
    func attach(using window: UIWindow) {
        guard overlayWindow == nil, let scene = window.windowScene else { return }
        mainWindow = window

        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.isHidden = true
        overlay.alpha = 0
        overlay.backgroundColor = .clear
        overlay.accessibilityViewIsModal = true
        overlay.overrideUserInterfaceStyle = window.overrideUserInterfaceStyle

        let controller = UIHostingController(rootView: AnyView(EmptyView()))
        controller.view.backgroundColor = .clear
        overlay.rootViewController = controller

        overlayWindow = overlay
        hosting = controller
    }

    /// Shows `content` above everything else, including any already-presented sheet.
    func show<Content: View>(@ViewBuilder content: () -> Content) {
        guard let overlay = overlayWindow, let hosting else { return }
        hosting.rootView = AnyView(content())
        guard overlay.isHidden else { return }
        overlay.isHidden = false
        overlay.makeKeyAndVisible()
        UIView.animate(withDuration: 0.25) { overlay.alpha = 1 }
    }

    func hide() {
        guard let overlay = overlayWindow, !overlay.isHidden else { return }
        UIView.animate(withDuration: 0.25) {
            overlay.alpha = 0
        } completion: { [weak self] _ in
            overlay.isHidden = true
            self?.hosting?.rootView = AnyView(EmptyView())
            self?.mainWindow?.makeKey()
        }
    }
}

/// Resolves the `UIWindow` hosting this SwiftUI hierarchy so `SecureOverlayWindow` can attach
/// a sibling window to the same `UIWindowScene`. Invisible and non-interactive; carries no UI.
struct WindowAccessor: UIViewRepresentable {
    let onResolve: (UIWindow) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        resolve(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        resolve(from: uiView)
    }

    private func resolve(from view: UIView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            onResolve(window)
        }
    }
}
