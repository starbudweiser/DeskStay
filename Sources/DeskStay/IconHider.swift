import AppKit

/// Masque les icônes du Bureau en posant, juste au-dessus d'elles, une fenêtre affichant le fond d'écran.
/// Ne modifie aucun réglage du Finder et ne le relance pas. Les fenêtres d'applications restent au-dessus.
@MainActor
final class IconHider {
    private var windows: [NSWindow] = []

    var isHidden: Bool { !windows.isEmpty }

    func toggle() {
        isHidden ? show() : hide()
    }

    func hide() {
        removeWindows()
        for screen in NSScreen.screens {
            windows.append(makeWindow(for: screen))
        }
    }

    func show() {
        removeWindows()
    }

    /// À appeler quand les écrans ou le fond d'écran changent.
    func refresh() {
        if isHidden { hide() }
    }

    private func removeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.hasShadow = false
        window.backgroundColor = .black
        window.ignoresMouseEvents = false // évite d'ouvrir par erreur une icône invisible

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
        }
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        return window
    }
}
