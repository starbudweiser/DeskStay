import AppKit
import DeskStayCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Images des icônes telles que le Finder les affiche : vignette du contenu (PDF, images…) quand elle existe,
/// sinon icône du type de fichier. Préparées à l'avance pour que l'animation n'attende jamais.
@MainActor
enum IconCache {
    struct Picture { let image: CGImage; let isThumbnail: Bool }
    private struct Entry { let stamp: Date?; let picture: Picture }
    private static var entries: [String: Entry] = [:]

    private static func key(_ path: String, _ size: CGFloat, _ scale: CGFloat) -> String { "\(path)|\(Int(size))|\(Int(scale))" }

    private static func stamp(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func picture(forPath path: String, size: CGFloat, scale: CGFloat) -> Picture? {
        guard let entry = entries[key(path, size, scale)], entry.stamp == stamp(path) else { return nil }
        return entry.picture
    }

    /// Lance la création des vignettes manquantes ou périmées, sans attendre.
    static func prefetch(paths: [String], size: CGFloat, scale: CGFloat) {
        for path in paths where picture(forPath: path, size: size, scale: scale) == nil {
            let url = URL(fileURLWithPath: path)
            let isAlias = (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile ?? false
            let currentStamp = stamp(path)
            let k = key(path, size, scale)
            if isAlias {
                if let cg = aliasIcon(url, size: size, scale: scale) ?? typeIcon(path, size: size, scale: scale) {
                    entries[k] = Entry(stamp: currentStamp, picture: Picture(image: cg, isThumbnail: false))
                }
                continue
            }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                        representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                let cg = representation?.cgImage
                let isThumbnail = representation.map { $0.type == .thumbnail || $0.type == .lowQualityThumbnail } ?? false
                Task { @MainActor in
                    if let cg {
                        entries[k] = Entry(stamp: currentStamp, picture: Picture(image: cg, isThumbnail: isThumbnail))
                    } else if let icon = typeIcon(path, size: size, scale: scale) {
                        entries[k] = Entry(stamp: currentStamp, picture: Picture(image: icon, isThumbnail: false))
                    }
                }
            }
        }
    }

    static func typeIcon(_ path: String, size: CGFloat, scale: CGFloat) -> CGImage? {
        render(NSWorkspace.shared.icon(forFile: path), size: size, scale: scale)
    }

    private static func render(_ image: NSImage, size: CGFloat, scale: CGFloat) -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: size * scale, height: size * scale)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static let aliasArrow = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AliasBadgeIcon.icns")

    /// Icône d'un alias comme dans le Finder : icône de ce qu'il désigne (dossier ou type du fichier) avec le badge flèche
    /// en bas à gauche. La cible est lue dans l'alias lui-même : elle peut être dans iCloud Drive, où DeskStay n'a pas accès,
    /// et le système ne sait alors donner qu'une feuille générique.
    private static func aliasIcon(_ url: URL, size: CGFloat, scale: CGFloat) -> CGImage? {
        guard let data = try? URL.bookmarkData(withContentsOf: url),
              let values = URL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .pathKey], fromBookmarkData: data) else { return nil }
        let base: NSImage
        if values.isDirectory == true, values.isPackage != true {
            base = NSWorkspace.shared.icon(for: .folder)
        } else if let path = values.path, case let ext = (path as NSString).pathExtension, !ext.isEmpty,
                  let type = UTType(filenameExtension: ext) {
            base = NSWorkspace.shared.icon(for: type)
        } else {
            return nil
        }
        let composed = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            // Badge : pastille claire et flèche (le dessin de la flèche n'occupe que le coin du fichier du système).
            let side = rect.width * 0.31
            let badge = NSRect(x: 0, y: 0, width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = rect.width * 0.03
            shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.015)
            shadow.set()
            NSColor(white: 0.9, alpha: 1).setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0.62, alpha: 1).setStroke()
            let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            if let arrow = aliasArrow {
                let source = NSRect(x: 0, y: 0, width: arrow.size.width * 0.165, height: arrow.size.height * 0.2)
                let target = badge.insetBy(dx: side * 0.2, dy: side * 0.2)
                arrow.draw(in: target, from: source, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        return render(composed, size: size, scale: scale)
    }

    /// Les éléments du Bureau sont soit dans ~/Desktop, soit des volumes montés.
    static func path(forDesktopItem name: String) -> String {
        let home = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/" + name)
        if FileManager.default.fileExists(atPath: home) { return home }
        return "/Volumes/" + name
    }
}

/// Fait glisser les icônes du Bureau vers leur place au lieu de les faire sauter une à une.
///
/// Le Finder met environ 17 ms à déplacer une icône, sans animation : 50 icônes se déplacent en cascade pendant 1 s.
/// Pendant ce temps, des fenêtres transparentes posées au-dessus des icônes montrent le fond d'écran à la place
/// des icônes qui bougent, et des copies de ces icônes glissent en 60 images/s (Core Animation, qui continue même
/// quand le fil principal attend le Finder). Les icônes qui ne bougent pas ne sont pas touchées.
@MainActor
enum IconAnimator {
    static var duration: CFTimeInterval = 0.25
    static var labelWeight: NSFont.Weight = .medium
    private static let cellWidth: CGFloat = 112 // largeur de retour à la ligne des noms, déduite des noms coupés par le Finder
    private static let labelHeight: CGFloat = 36
    private static let labelGap: CGFloat = 4

    private static var cachedStyle: (iconSize: Int, textSize: Int)?

    /// Lit une fois la taille des icônes et du texte : évite un aller-retour avec le Finder avant chaque animation.
    @discardableResult
    static func warm(_ bridge: FinderBridge, displays: [DisplaySnapshot] = Displays.current()) -> (iconSize: Int, textSize: Int) {
        if let style = try? bridge.readDesktopStyle() { cachedStyle = style }
        let size = cachedStyle?.iconSize ?? 64
        if let icons = try? bridge.readDesktop(displays: displays) {
            IconCache.prefetch(paths: icons.map { IconCache.path(forDesktopItem: $0.name) }, size: CGFloat(size), scale: maxScale)
        }
        return cachedStyle ?? (iconSize: 64, textSize: 12)
    }

    static var maxScale: CGFloat { NSScreen.screens.map(\.backingScaleFactor).max() ?? 2 }

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
        let style = cachedStyle ?? warm(bridge)
        let stage = Stage(moves: moves, iconSize: CGFloat(style.iconSize), textSize: CGFloat(style.textSize))
        guard stage.isReady else { return try bridge.restoreDesktop(icons, displays: displays) }
        stage.show()
        stage.startAnimation()
        let started = CACurrentMediaTime()
        defer { stage.close() }
        let moved = try bridge.restoreDesktop(icons, displays: displays) // bloque ~1 s ; l'animation continue sans nous
        let remaining = duration + 0.05 - (CACurrentMediaTime() - started)
        if remaining > 0 { pump(remaining) }
        stage.fadeOut()
        pump(0.12)
        warm(bridge)
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
                masks[move.fromDisplay.id, default: []] += Self.cutouts(move.name, at: move.from, in: move.fromDisplay, iconSize: iconSize, textSize: textSize)
                masks[move.toDisplay.id, default: []] += Self.cutouts(move.name, at: move.to, in: move.toDisplay, iconSize: iconSize, textSize: textSize)
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
                surface.window.orderFrontRegardless()
            }
            CATransaction.flush()
        }

        func startAnimation() {
            for traveller in travellers {
                let slide = CABasicAnimation(keyPath: "position")
                slide.fromValue = NSValue(point: traveller.from)
                slide.toValue = NSValue(point: traveller.to)
                slide.duration = IconAnimator.duration
                // départ immédiat, arrivée en douceur : aucun temps mort avant le mouvement
                slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.85, 0.25, 1)
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
                fade.duration = 0.1
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

        /// Deux rectangles (repère de la fenêtre, origine en bas à gauche) : l'image avec la marge de son ombre, et le nom mesuré.
        /// Au plus juste, pour ne pas rogner le nom d'une icône voisine qui reste en place.
        private static func cutouts(_ name: String, at global: CGPoint, in display: DisplaySnapshot,
                                    iconSize: CGFloat, textSize: CGFloat) -> [CGRect] {
            let x = global.x - display.frame.minX
            let y = display.frame.height - (global.y - display.frame.minY)
            let image = CGRect(x: x - iconSize / 2, y: y - iconSize / 2, width: iconSize, height: iconSize).insetBy(dx: -8, dy: -8)
            let text = labelText(of: name, textSize: textSize) as NSString
            let measured = text.boundingRect(with: NSSize(width: IconAnimator.cellWidth, height: IconAnimator.labelHeight),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                             attributes: [.font: labelFont(textSize)])
            let width = min(IconAnimator.cellWidth, ceil(measured.width) + 4)
            let height = min(IconAnimator.labelHeight, ceil(measured.height) + 2)
            let top = y - iconSize / 2 - IconAnimator.labelGap
            let label = CGRect(x: x - width / 2, y: top - height, width: width, height: height).insetBy(dx: -3, dy: -2)
            return [image, label]
        }

        private static func labelImage(_ text: String, font: NSFont, size: CGSize, scale: CGFloat) -> CGImage? {
            let image = NSImage(size: size, flipped: false) { rect in
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byClipping
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white,
                                                                 .paragraphStyle: paragraph, .shadow: shadow]
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    (line as NSString).draw(in: NSRect(x: 0, y: rect.height - lineHeight * CGFloat(i + 1), width: rect.width, height: lineHeight),
                                            withAttributes: attributes)
                }
                return true
            }
            var rect = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }

        private static func labelFont(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: IconAnimator.labelWeight) }

        /// Nom sur au plus deux lignes, comme le Finder : à la ligne sur une espace sinon au caractère,
        /// et si la suite ne tient pas sur la deuxième ligne, elle est tronquée en son milieu.
        private static func labelText(of name: String, textSize: CGFloat) -> String {
            let font = labelFont(textSize)
            let width = IconAnimator.cellWidth
            func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
            let text = displayName(of: name)
            if w(text) <= width { return text }
            var n = text.count
            while n > 1, w(String(text.prefix(n))) > width { n -= 1 }
            let chars = Array(text)
            if n < chars.count, chars[n] != " ", let space = chars[0..<n].lastIndex(of: " "), space > 0 { n = space }
            let first = String(chars[0..<n]).trimmingCharacters(in: .whitespaces)
            let rest = String(chars[n...]).trimmingCharacters(in: .whitespaces)
            if w(rest) <= width { return first + "\n" + rest }
            let r = Array(rest)
            var keep = r.count
            while keep > 2 {
                keep -= 1
                let head = String(r.prefix((keep - 2) / 2)), tail = String(r.suffix(keep - (keep - 2) / 2))
                if w(head + "..." + tail) <= width { return first + "\n" + head + "..." + tail }
            }
            return first + "\n" + String(r.prefix(2)) + "..."
        }

        private static func displayName(of name: String) -> String {
            FileManager.default.displayName(atPath: IconCache.path(forDesktopItem: name))
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

            let path = IconCache.path(forDesktopItem: name)
            let image = CALayer()
            image.frame = CGRect(x: (width - iconSize) / 2, y: IconAnimator.labelHeight + IconAnimator.labelGap, width: iconSize, height: iconSize)
            image.contentsScale = scale
            let picture = IconCache.picture(forPath: path, size: iconSize, scale: IconAnimator.maxScale)
                ?? IconCache.typeIcon(path, size: iconSize, scale: IconAnimator.maxScale).map { IconCache.Picture(image: $0, isThumbnail: false) }
            if let picture {
                // Une vignette (aperçu d'un PDF, d'une image…) garde ses proportions, un peu réduite, coins arrondis, comme dans le Finder.
                let shrink: CGFloat = picture.isThumbnail ? 0.92 : 1
                let ratio = CGFloat(picture.image.width) / CGFloat(max(picture.image.height, 1))
                let box = iconSize * shrink
                let drawn = ratio >= 1 ? CGSize(width: box, height: box / ratio) : CGSize(width: box * ratio, height: box)
                image.frame = CGRect(x: (width - drawn.width) / 2, y: IconAnimator.labelHeight + IconAnimator.labelGap + (iconSize - drawn.height) / 2,
                                     width: drawn.width, height: drawn.height)
                if picture.isThumbnail {
                    let inner = CALayer()
                    inner.frame = image.bounds
                    inner.contents = picture.image
                    inner.contentsScale = scale
                    inner.cornerRadius = 3.5
                    inner.masksToBounds = true
                    inner.borderWidth = 0.5
                    inner.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
                    image.addSublayer(inner)
                    image.shadowPath = CGPath(roundedRect: image.bounds, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
                } else {
                    image.contents = picture.image
                }
            }
            image.shadowColor = NSColor.black.cgColor
            image.shadowOpacity = 0.4
            image.shadowRadius = 3
            image.shadowOffset = CGSize(width: 0, height: -2)
            group.addSublayer(image)

            // Le nom est dessiné par AppKit (lissage du texte du Finder) : CATextLayer le rend plus fin et plus pâle.
            let label = CALayer()
            label.frame = CGRect(x: 0, y: 0, width: width, height: IconAnimator.labelHeight)
            label.contentsScale = scale
            label.contents = Self.labelImage(Self.labelText(of: name, textSize: textSize), font: Self.labelFont(textSize),
                                             size: CGSize(width: width, height: IconAnimator.labelHeight), scale: scale)
            group.addSublayer(label)
            return group
        }

    }
}
