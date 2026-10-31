import AppKit
import ApplicationServices
import DeskStayCore

/// Capture et restauration des fenêtres d'applications via l'API Accessibilité.
@MainActor
enum WindowBridge {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Affiche la demande système d'accès Accessibilité (sans effet si déjà accordé).
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    struct LiveWindow {
        let element: AXUIElement
        let title: String
        let index: Int
        let frame: CGRect
        let isFullScreen: Bool
    }

    /// Apps ordinaires en cours d'exécution (le Finder est traité à part, par AppleScript).
    static func candidateApps() -> [NSRunningApplication] {
        let me = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier else { return false }
            return id != "com.apple.finder" && id != me
        }
    }

    /// Fenêtres standard, non réduites, de l'espace courant.
    static func windows(of app: NSRunningApplication) -> [LiveWindow] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // une app figée ne bloque pas DeskStay
        guard let list: [AXUIElement] = attribute(axApp, kAXWindowsAttribute) else { return [] }
        var result: [LiveWindow] = []
        for window in list {
            let subrole: String? = attribute(window, kAXSubroleAttribute)
            guard subrole == (kAXStandardWindowSubrole as String) else { continue }
            if let minimized: Bool = attribute(window, kAXMinimizedAttribute), minimized { continue }
            guard let origin = point(window), let size = size(window), size.width > 0, size.height > 0 else { continue }
            let title: String = attribute(window, kAXTitleAttribute) ?? ""
            let fullScreen: Bool = attribute(window, "AXFullScreen") ?? false
            result.append(LiveWindow(element: window, title: title, index: result.count,
                                     frame: CGRect(origin: origin, size: size), isFullScreen: fullScreen))
        }
        return result
    }

    static func capture(displays: [DisplaySnapshot], apps: [NSRunningApplication]) -> [AppWindowState] {
        var states: [AppWindowState] = []
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            for w in windows(of: app) where !w.isFullScreen { // leur cadre est celui de l'écran, pas une position à rétablir
                let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
                guard let d = Geometry.display(containing: center, in: displays) else { continue }
                let relative = CGRect(x: w.frame.minX - d.frame.minX, y: w.frame.minY - d.frame.minY,
                                      width: w.frame.width, height: w.frame.height)
                states.append(AppWindowState(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                             title: w.title, index: w.index, displayID: d.id,
                                             displayWidth: Double(d.frame.width), displayHeight: Double(d.frame.height),
                                             relativeFrame: CodableRect(relative)))
            }
        }
        return states
    }

    struct RestoreResult {
        var moved = 0
        var notFound = 0
        var failed = 0
        /// Fenêtres en plein écran : macOS interdit de les déplacer, elles sont laissées telles quelles.
        var fullScreen = 0
        /// « App : titre » des fenêtres qui ont refusé d'être déplacées.
        var failures: [String] = []
    }

    /// Les apps fermées ne sont pas lancées : leurs fenêtres comptent comme « non trouvées ».
    static func restore(_ saved: [AppWindowState], displays: [DisplaySnapshot]) -> RestoreResult {
        var result = RestoreResult()
        let running = candidateApps()
        for (bundleID, states) in Dictionary(grouping: saved, by: \.bundleID) {
            guard let app = running.first(where: { $0.bundleIdentifier == bundleID }) else {
                result.notFound += states.count
                continue
            }
            let live = windows(of: app)
            let pairs = WindowMatcher.match(saved: states, current: live.map { .init(title: $0.title, index: $0.index) })
            for pair in pairs {
                let state = states[pair.saved]
                if live[pair.current].isFullScreen {
                    result.fullScreen += 1
                    continue
                }
                guard let display = Geometry.targetDisplay(id: state.displayID, in: displays) else { continue }
                let target = Geometry.mapRelativeFrame(state.relativeFrame.cgRect,
                                                       savedDisplaySize: CGSize(width: state.displayWidth, height: state.displayHeight),
                                                       to: display.frame)
                if setFrame(live[pair.current].element, target) {
                    result.moved += 1
                } else {
                    result.failed += 1
                    result.failures.append("\(state.appName) : \(live[pair.current].title.isEmpty ? "sans titre" : live[pair.current].title)")
                }
            }
            result.notFound += states.count - pairs.count
        }
        return result
    }

    // MARK: AX

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue) // sûr : type vérifié par CFGetTypeID juste au-dessus
    }

    private static func point(_ element: AXUIElement) -> CGPoint? {
        guard let v = axValue(element, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        guard let v = axValue(element, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    /// Taille, puis position, puis taille à nouveau : certaines apps refusent une taille qui sortirait de l'écran
    /// tant que la fenêtre n'a pas été déplacée. Une fenêtre de taille fixe compte comme réussie si elle a changé de place.
    private static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let pv = AXValueCreate(.cgPoint, &origin), let sv = AXValueCreate(.cgSize, &size) else { return false }
        let first = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sv)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pv)
        let second = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sv)
        _ = (first, second)
        return moved == .success
    }
}
