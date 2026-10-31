import ColorSync
import CoreGraphics
import DeskStayCore
import Foundation

enum Displays {
    /// Écrans actifs, en coordonnées Quartz globales (origine en haut à gauche de l'écran principal).
    static func current() -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            DisplaySnapshot(id: stableID(for: id), frame: CGDisplayBounds(id), isMain: CGDisplayIsMain(id) != 0)
        }
    }

    /// UUID de l'écran (stable entre redémarrages) ; repli sur le numéro de session si indisponible.
    static func stableID(for id: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return "display-\(id)"
    }
}
