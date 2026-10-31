import CoreGraphics
import Foundation

public enum Geometry {
    /// Ramène une valeur dans [0, 1] ; une valeur non finie devient 0.
    public static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// Exprime un point en fraction du rectangle (une icône en bas à droite reste en bas à droite).
    public static func normalize(_ point: CGPoint, in rect: CGRect) -> NormalizedPoint {
        guard rect.width > 0, rect.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        let x = Double((point.x - rect.minX) / rect.width)
        let y = Double((point.y - rect.minY) / rect.height)
        return NormalizedPoint(x: clampUnit(x), y: clampUnit(y))
    }

    public static func denormalize(_ point: NormalizedPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: Double(rect.minX) + clampUnit(point.x) * Double(rect.width),
                y: Double(rect.minY) + clampUnit(point.y) * Double(rect.height))
    }

    /// Distance d'un point au rectangle (0 s'il est dedans).
    public static func distance(_ point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return Double((dx * dx + dy * dy).squareRoot())
    }

    /// Écran contenant le point, sinon l'écran le plus proche.
    public static func display(containing point: CGPoint, in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        if let hit = displays.first(where: { $0.frame.contains(point) }) { return hit }
        return displays.min { distance(point, to: $0.frame) < distance(point, to: $1.frame) }
    }

    public static func mainDisplay(in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        displays.first(where: { $0.isMain }) ?? displays.first
    }

    /// Écran d'origine s'il est encore branché, sinon l'écran principal.
    public static func targetDisplay(id: String, in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        displays.first(where: { $0.id == id }) ?? mainDisplay(in: displays)
    }

    /// Replace un cadre relatif sur un écran.
    /// - Même taille d'écran : cadre restitué à l'identique (y compris s'il dépasse volontairement).
    /// - Taille différente : origine mise à l'échelle, taille limitée à l'écran, cadre maintenu dans l'écran.
    public static func mapRelativeFrame(_ relative: CGRect, savedDisplaySize: CGSize, to display: CGRect) -> CGRect {
        let sameSize = abs(savedDisplaySize.width - display.width) < 0.5
            && abs(savedDisplaySize.height - display.height) < 0.5
        if sameSize {
            return CGRect(x: display.minX + relative.minX, y: display.minY + relative.minY,
                          width: relative.width, height: relative.height)
        }
        let sx = savedDisplaySize.width > 0 ? display.width / savedDisplaySize.width : 1
        let sy = savedDisplaySize.height > 0 ? display.height / savedDisplaySize.height : 1
        let width = min(relative.width, display.width)
        let height = min(relative.height, display.height)
        let x = min(max(display.minX + relative.minX * sx, display.minX), display.maxX - width)
        let y = min(max(display.minY + relative.minY * sy, display.minY), display.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Garde un cadre global visible : il est ramené dans l'écran qui contient (ou est le plus proche de) son centre.
    public static func fit(_ rect: CGRect, in displays: [DisplaySnapshot]) -> CGRect {
        guard let display = display(containing: CGPoint(x: rect.midX, y: rect.midY), in: displays) else {
            return rect
        }
        let f = display.frame
        let width = min(rect.width, f.width)
        let height = min(rect.height, f.height)
        let x = min(max(rect.minX, f.minX), f.maxX - width)
        let y = min(max(rect.minY, f.minY), f.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
