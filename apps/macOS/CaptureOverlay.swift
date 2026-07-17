import AppKit

/// Always-on-top, click-through window that draws a colored border around the
/// active screen while capturing is on — the same visual UTM uses to signal
/// "your keyboard is going somewhere else." Purely a redundant *visual* cue;
/// the state is also announced and reflected in the menu, never conveyed by
/// the border alone.
@MainActor
final class CaptureOverlay {
    private var window: NSWindow?

    func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            window?.orderOut(nil)
            window = nil
        }
    }

    private func show() {
        guard window == nil, let screen = NSScreen.main else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.hasShadow = false
        // Not a focusable / accessible element — it carries no information a
        // screen-reader user needs to reach; the announcement does that.
        window.setAccessibilityElement(false)

        let border = BorderView(frame: screen.frame)
        window.contentView = border
        window.orderFrontRegardless()
        self.window = window
    }
}

/// Draws just the inner edge stroke.
private final class BorderView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let thickness: CGFloat = 6
        let inset = thickness / 2
        let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
        path.lineWidth = thickness
        NSColor.systemRed.setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
