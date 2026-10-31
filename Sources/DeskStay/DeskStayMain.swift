import AppKit

@main
enum DeskStayMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // app de barre de menus, sans icône dans le Dock
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
