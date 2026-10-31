import AppKit
import DeskStayCore

/// Fait glisser les icônes du Bureau vers leur place au lieu de les faire sauter une à une.
///
/// Le Finder met environ 17 ms à déplacer une icône, sans animation : 50 icônes se déplacent en cascade pendant 1 s.
/// Pendant ce temps, des fenêtres transparentes posées au-dessus des icônes montrent le fond d'écran à la place
/// des icônes qui bougent, et des copies de ces icônes glissent en 60 images/s (Core Animation, qui continue même
/// quand le fil principal attend le Finder). Les icônes qui ne bougent pas ne sont pas touchées.
@MainActor
enum IconAnimator {
    static var duration: CFTimeInterval = 0.6
    private static let cellWidth: CGFloat = 112
    private static let labelHeight: CGFloat = 36
    private static let labelGap: CGFloat = 4

    private struct Move {
        let name: String
        let from: CGPoint
        let to: CGPoint
        let fromDisplay: DisplaySnapshot
        let toDisplay: DisplaySnapshot
    }

    /// Retourne le nombre d'icônes déplacées par le Finder.
    static func restore(_ icons: [DesktopIcon], displays: [DisplaySnapshot], bridge: FinderBridge) throws -> Int {
        let moves = (try? plan(icons, displays: displays, bridge: bridge)) ?? []
        guard !moves.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return try bridge.restoreDesktop(icons, displays: displays)
        }
        let style = (try? bridge.readDesktopStyle()) ?? (iconSize: 64, textSize: 12)
        let stage = Stage(moves: moves, iconSize: CGFloat(style.iconSize), textSize: CGFloat(style.textSize))
        guard stage.isReady else { return try bridge.restoreDesktop(icons, displays: displays) }

        stage.show()
        pump(0.14)
        stage.startAnimation()
        let started = CACurrentMediaTime()
        defer { stage.close() }
        let moved = try bridge.restoreDesktop(icons, displays: displays) // bloque ~1 s ; l'animation continue sans nous
        let remaining = duration + 0.05 - (CACurrentMediaTime() - started)
        if remaining > 0 { pump(remaining) }
        stage.fadeOut()
        pump(0.18)
        return moved
    }

    private static func plan(_ icons: [DesktopIcon], displays: [DisplaySnapshot], bridge: FinderBridge) throws -> [Move] {
        let current = Dictionary(try bridge.readDesktop(displays: displays).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var moves: [Move] = []
        for icon in icons {
            guard let now = current[icon.name],
                  let fromDisplay = displays.first(where: { $0.id == now.displayID }),
                  let toDisplay = Geometry.targetDisplay(id: icon.displayID, in: displays) else { continue }
            let from = Geometry.denormalize(now.position, in: fromDisplay.frame)
            let to = Geometry.denormalize(icon.position, in: toDisplay.frame)
            // Le Finder arrondit à l'entier : en dessous de 3 px l'icône est déjà à sa place.
            if hypot(to.x - from.x, to.y - from.y) >= 3 {
                moves.append(Move(name: icon.name, from: from, to: to, fromDisplay: fromDisplay, toDisplay: toDisplay))
            }
        }
        return moves
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Scène

    /// Fenêtres transparentes (une par écran concerné) avec le fond d'écran découpé sous les icônes qui bougent.
    @MainActor
    private final class Stage {
        private struct Surface {
            let window: NSWindow
            let root: CALayer
            let display: DisplaySnapshot
            let scale: CGFloat
        }

        private var surfaces: [String: Surface] = [:]
        private var travellers: [(layer: CALayer, from: CGPoint, to: CGPoint)] = []
        private var leaving: [CALayer] = []
        private var arriving: [CALayer] = []
        private let iconSize: CGFloat
        private let textSize: CGFloat
        let isReady: Bool

        init(moves: [Move], iconSize: CGFloat, textSize: CGFloat) {
            self.iconSize = iconSize
            self.textSize = textSize
            var ok = true
            var masks: [String: [CGRect]] = [:]
            var pending: [(Move, Bool)] = []

            for move in moves {
                for display in [move.fromDisplay, move.toDisplay] where surfaces[display.id] == nil {
                    guard let screen = Self.screen(for: display) else { ok = false; continue }
                    surfaces[display.id] = Self.makeSurface(screen: screen, display: display)
                }
                guard surfaces[move.fromDisplay.id] != nil, surfaces[move.toDisplay.id] != nil else { ok = false; continue }
                masks[move.fromDisplay.id, default: []].append(Self.cell(at: move.from, in: move.fromDisplay, iconSize: iconSize))
                masks[move.toDisplay.id, default: []].append(Self.cell(at: move.to, in: move.toDisplay, iconSize: iconSize))
                pending.append((move, move.fromDisplay.id != move.toDisplay.id))
            }
            isReady = ok && !surfaces.isEmpty

            for (id, surface) in surfaces {
                Self.addWallpaper(to: surface, cells: masks[id] ?? [])
            }
            for (move, crossesDisplays) in pending {
                guard let source = surfaces[move.fromDisplay.id], let target = surfaces[move.toDisplay.id] else { continue }
                let from = Self.point(move.from, in: source)
                let to = Self.point(move.to, in: target)
                let sourceLayer = makeIconLayer(move.name, scale: source.scale)
                sourceLayer.position = from
                source.root.addSublayer(sourceLayer)
                if crossesDisplays {
                    let targetLayer = makeIconLayer(move.name, scale: target.scale)
                    targetLayer.position = to
                    targetLayer.opacity = 0
                    target.root.addSublayer(targetLayer)
                    leaving.append(sourceLayer)
                    arriving.append(targetLayer)
                } else {
                    travellers.append((sourceLayer, from, to))
                }
            }
        }

        func show() {
            for surface in surfaces.values {
                surface.root.opacity = 0
                surface.window.orderFrontRegardless()
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.12
                surface.root.opacity = 1
                surface.root.add(fade, forKey: "fadeIn")
            }
            CATransaction.flush()
        }

        func startAnimation() {
            for traveller in travellers {
                let slide = CABasicAnimation(keyPath: "position")
                slide.fromValue = NSValue(point: traveller.from)
                slide.toValue = NSValue(point: traveller.to)
                slide.duration = IconAnimator.duration
                slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                traveller.layer.position = traveller.to
                traveller.layer.add(slide, forKey: "slide")
            }
            for (out, in_) in zip(leaving, arriving) {
                out.opacity = 0
                in_.opacity = 1
                for (layer, from, to) in [(out, 1.0, 0.0), (in_, 0.0, 1.0)] {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = from
                    fade.toValue = to
                    fade.duration = IconAnimator.duration * 0.6
                    layer.add(fade, forKey: "cross")
                }
            }
            CATransaction.flush() // envoie les animations au serveur de rendu avant que le fil principal ne bloque
        }

        func fadeOut() {
            for surface in surfaces.values {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.15
                surface.root.opacity = 0
                surface.root.add(fade, forKey: "fadeOut")
            }
            CATransaction.flush()
        }

        func close() {
            for surface in surfaces.values { surface.window.orderOut(nil) }
            surfaces.removeAll()
        }

        // MARK: Construction

        private static func screen(for display: DisplaySnapshot) -> NSScreen? {
            NSScreen.screens.first { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayBounds(CGDirectDisplayID(number.uint32Value)) == display.frame
            }
        }

        private static func makeSurface(screen: NSScreen, display: DisplaySnapshot) -> Surface {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.hasShadow = false
            window.isOpaque = false
            window.backgroundColor = .clear
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            return Surface(window: window, root: view.layer!, display: display, scale: screen.backingScaleFactor)
        }

        /// Rectangle (repère de la fenêtre, origine en bas à gauche) couvrant une icône et son nom.
        private static func cell(at global: CGPoint, in display: DisplaySnapshot, iconSize: CGFloat) -> CGRect {
            let x = global.x - display.frame.minX
            let y = display.frame.height - (global.y - display.frame.minY)
            let height = iconSize + IconAnimator.labelGap + IconAnimator.labelHeight
            return CGRect(x: x - IconAnimator.cellWidth / 2, y: y - iconSize / 2 - IconAnimator.labelGap - IconAnimator.labelHeight,
                          width: IconAnimator.cellWidth, height: height)
        }

        private static func point(_ global: CGPoint, in surface: Surface) -> CGPoint {
            CGPoint(x: global.x - surface.display.frame.minX,
                    y: surface.display.frame.height - (global.y - surface.display.frame.minY))
        }

        private static func addWallpaper(to surface: Surface, cells: [CGRect]) {
            guard let screen = screen(for: surface.display) else { return }
            let wallpaper = CALayer()
            wallpaper.frame = CGRect(origin: .zero, size: screen.frame.size)
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            if let color = options[.fillColor] as? NSColor { wallpaper.backgroundColor = color.cgColor }
            let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
            let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
            switch scaling {
            case .scaleAxesIndependently: wallpaper.contentsGravity = .resize
            case .scaleNone: wallpaper.contentsGravity = .center
            case .scaleProportionallyDown, .scaleProportionallyUpOrDown:
                wallpaper.contentsGravity = clipping ? .resizeAspectFill : .resizeAspect
            @unknown default: wallpaper.contentsGravity = .resizeAspectFill
            }
            wallpaper.contentsScale = surface.scale
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url),
               let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                wallpaper.contents = cg
            }
            let mask = CALayer()
            mask.frame = wallpaper.bounds
            for rect in cells {
                let patch = CALayer()
                patch.frame = rect
                patch.backgroundColor = NSColor.black.cgColor
                mask.addSublayer(patch)
            }
            wallpaper.mask = mask
            surface.root.addSublayer(wallpaper)
        }

        /// Copie d'une icône : image du fichier + nom dessous. L'ancre est le centre de l'image, comme la position du Finder.
        private func makeIconLayer(_ name: String, scale: CGFloat) -> CALayer {
            let width = IconAnimator.cellWidth
            let height = iconSize + IconAnimator.labelGap + IconAnimator.labelHeight
            let group = CALayer()
            group.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            group.anchorPoint = CGPoint(x: 0.5, y: (IconAnimator.labelHeight + IconAnimator.labelGap + iconSize / 2) / height)

            let path = Self.path(forDesktopItem: name)
            let image = CALayer()
            image.frame = CGRect(x: (width - iconSize) / 2, y: IconAnimator.labelHeight + IconAnimator.labelGap, width: iconSize, height: iconSize)
            image.contentsScale = scale
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: iconSize, height: iconSize)
            image.contents = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
            group.addSublayer(image)

            let label = CATextLayer()
            label.frame = CGRect(x: 0, y: 0, width: width, height: IconAnimator.labelHeight)
            label.contentsScale = scale
            label.string = FileManager.default.displayName(atPath: path)
            label.font = NSFont.systemFont(ofSize: textSize, weight: .medium)
            label.fontSize = textSize
            label.foregroundColor = NSColor.white.cgColor
            label.alignmentMode = .center
            label.isWrapped = true
            label.truncationMode = .middle
            label.shadowColor = NSColor.black.cgColor
            label.shadowOpacity = 1
            label.shadowRadius = 2
            label.shadowOffset = CGSize(width: 0, height: -1)
            group.addSublayer(label)
            return group
        }

        /// Les éléments du Bureau sont soit dans ~/Desktop, soit des volumes montés.
        private static func path(forDesktopItem name: String) -> String {
            let home = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/" + name)
            if FileManager.default.fileExists(atPath: home) { return home }
            return "/Volumes/" + name
        }
    }
}
