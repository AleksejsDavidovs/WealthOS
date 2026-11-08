import SwiftUI
import UIKit

/// A dedicated `UIWindow` above the app's main window, used for the lock screen and the
/// app-switcher privacy cover.
///
/// Sheets, full-screen covers, popovers and dialogs are UIKit view controllers presented
/// *inside* the main window, above all of its SwiftUI content. A ZStack/overlay lock screen
/// is part of that content, so any open sheet is drawn above it. A separate window at a
/// higher `windowLevel` sits above the main window's entire presentation stack.
///
/// While shown, the main window is also made non-interactive, hidden from VoiceOver and its
/// first responder resigned, so neither touches, assistive tech nor the keyboard can reach
/// the hidden content. Open sheets are not dismissed, so unsaved forms survive the lock.
@MainActor
final class SecureOverlayWindow {
    private weak var mainWindow: UIWindow?
    private var overlayWindow: UIWindow?
    private var hosting: UIHostingController<AnyView>?
    /// Desired state; a fade-out finishing after a re-show must not hide the cover.
    private(set) var isShowing = false

    var isAttached: Bool { overlayWindow != nil }
    var isVisible: Bool { overlayWindow.map { !$0.isHidden && $0.alpha > 0 } ?? false }
    var windowLevel: UIWindow.Level? { overlayWindow?.windowLevel }

    func attach(using window: UIWindow) {
        guard overlayWindow == nil, let scene = window.windowScene else { return }
        mainWindow = window

        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.isHidden = true
        overlay.backgroundColor = .clear
        overlay.overrideUserInterfaceStyle = window.overrideUserInterfaceStyle

        let controller = UIHostingController(rootView: AnyView(EmptyView()))
        controller.view.backgroundColor = .clear
        controller.view.accessibilityViewIsModal = true
        overlay.rootViewController = controller

        overlayWindow = overlay
        hosting = controller
    }

    /// Appears instantly, never faded in: the app-switcher snapshot is taken right as the
    /// app resigns active and must not capture a half-transparent cover.
    func show<Content: View>(@ViewBuilder content: () -> Content) {
        guard let overlay = overlayWindow, let hosting else { return }
        hosting.rootView = AnyView(content())
        isShowing = true
        overlay.layer.removeAllAnimations()
        overlay.alpha = 1
        if overlay.isHidden {
            overlay.isHidden = false
            overlay.makeKeyAndVisible()
        }
        if let mainWindow {
            mainWindow.endEditing(true)
            mainWindow.isUserInteractionEnabled = false
            mainWindow.accessibilityElementsHidden = true
        }
    }

    func hide() {
        guard let overlay = overlayWindow, isShowing else { return }
        isShowing = false
        mainWindow?.isUserInteractionEnabled = true
        mainWindow?.accessibilityElementsHidden = false
        UIView.animate(withDuration: 0.25) {
            overlay.alpha = 0
        } completion: { [weak self] _ in
            guard let self, !self.isShowing else { return }
            overlay.isHidden = true
            self.hosting?.rootView = AnyView(EmptyView())
            self.mainWindow?.makeKey()
        }
    }
}

/// Reports the `UIWindow` hosting this SwiftUI hierarchy once, so `SecureOverlayWindow`
/// can attach to the same scene. Invisible and non-interactive.
struct WindowAccessor: UIViewRepresentable {
    let onResolve: (UIWindow) -> Void

    func makeUIView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onResolve
        return view
    }

    func updateUIView(_ uiView: WindowReportingView, context: Context) {}

    final class WindowReportingView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isHidden = true
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let callback = onWindow else { return }
            onWindow = nil
            // Defer out of the layout pass before creating/keying another window.
            DispatchQueue.main.async { callback(window) }
        }
    }
}
