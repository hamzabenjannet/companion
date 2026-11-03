import AppKit
import SwiftUI

@main struct CompanionApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .background(PrivateWindowConfigurator())
        }
        // Keep the companion above the meeting app while you share your screen.
        .windowLevel(.floating)
    }
}

/// Configures the hosting `NSWindow` as a private floating panel:
/// - asks the window server to leave it out of other apps' screen sharing
///   (`sharingType = .none`). This is best effort: Apple marks the setting as
///   legacy and ScreenCaptureKit-based sharing may still show the window.
///   The assistant's own recording excludes this app separately
///   (see `ScreenCapture.start()`).
/// - follows you across Spaces and over full-screen apps.
private struct PrivateWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowObservingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObservingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.sharingType = .none
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.hidesOnDeactivate = false
        }
    }
}
