import Carbon
import DeskStayCore
import Foundation

enum BridgeError: LocalizedError {
    case scriptCompile(String)
    case script(code: Int, message: String)
    case unexpectedResult(String)

    static let automationDenied = -1743

    var errorDescription: String? {
        switch self {
        case .scriptCompile(let m):
            return "Script interne invalide : \(m)"
        case .script(let code, let m):
            switch code {
            case BridgeError.automationDenied:
                return "DeskStay n'est pas autorisé à piloter le Finder (Réglages Système › Confidentialité et sécurité › Automatisation)."
            case -600, -609:
                return "Le Finder ne répond pas."
            case -1712:
                return "Le Finder a mis trop de temps à répondre."
            default:
                return "Erreur AppleScript \(code) : \(m)"
            }
        case .unexpectedResult(let m):
            return "Réponse inattendue du Finder : \(m)"
        }
    }

    var isAutomationDenied: Bool {
        if case .script(let code, _) = self { return code == BridgeError.automationDenied }
        return false
    }
}

/// Lecture / écriture des positions d'icônes et des fenêtres Finder par AppleScript.
/// Les données passent en paramètres de gestionnaires (jamais concaténées dans le source) : pas d'injection
/// possible via un nom de fichier. NSAppleScript n'est pas thread-safe : à utiliser sur le thread principal.
@MainActor
final class FinderBridge {
    /// Au-delà, les positions d'icônes d'une fenêtre Finder ne sont pas mémorisées (lenteur).
    static let maxIconsPerWindow = 500

    private let script: NSAppleScript

    init() throws {
        guard let s = NSAppleScript(source: Self.source) else { throw BridgeError.scriptCompile("création impossible") }
        var error: NSDictionary?
        guard s.compileAndReturnError(&error) else {
            throw BridgeError.scriptCompile((error?[NSAppleScript.errorMessage] as? String) ?? "inconnue")
        }
        script = s
    }

    // MARK: Bureau

    func readDesktop(displays: [DisplaySnapshot]) throws -> [DesktopIcon] {
        let result = try call("readdesktop")
        let parts = result.listItems
        guard parts.count == 2 else { throw BridgeError.unexpectedResult("bureau") }
        let names = parts[0].listItems
        let positions = parts[1].listItems
        var icons: [DesktopIcon] = []
        for (i, nameDesc) in names.enumerated() where i < positions.count {
            guard let name = nameDesc.stringValue, !name.isEmpty else { continue }
            let p = positions[i].listItems
            guard p.count == 2 else { continue }
            let point = CGPoint(x: p[0].doubleValue, y: p[1].doubleValue)
            guard let display = Geometry.display(containing: point, in: displays) else { continue }
            icons.append(DesktopIcon(name: name, displayID: display.id,
                                     position: Geometry.normalize(point, in: display.frame)))
        }
        return icons
    }

    /// Retourne le nombre d'icônes effectivement déplacées.
    func restoreDesktop(_ icons: [DesktopIcon], displays: [DisplaySnapshot]) throws -> Int {
        var names: [String] = []
        var xs: [Int] = []
        var ys: [Int] = []
        for icon in icons {
            guard let display = Geometry.targetDisplay(id: icon.displayID, in: displays) else { continue }
            let p = Geometry.denormalize(icon.position, in: display.frame)
            names.append(icon.name)
            xs.append(Int(p.x.rounded()))
            ys.append(Int(p.y.rounded()))
        }
        guard !names.isEmpty else { return 0 }
        let result = try call("restoredesktop", .list(strings: names), .list(ints: xs), .list(ints: ys))
        return Int(result.int32Value)
    }

    // MARK: Fenêtres Finder

    func readFinderWindows() throws -> [FinderWindowState] {
        let result = try call("readfinderwindows", NSAppleEventDescriptor(int32: Int32(Self.maxIconsPerWindow)))
        var windows: [FinderWindowState] = []
        for entry in result.listItems {
            let f = entry.listItems
            guard f.count == 5, let path = f[0].stringValue, !path.isEmpty else { continue }
            let b = f[1].listItems.map(\.doubleValue)
            guard b.count == 4, b[2] > b[0], b[3] > b[1] else { continue }
            let bounds = CodableRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
            let isIconView = f[2].booleanValue
            let names = f[3].listItems
            let positions = f[4].listItems
            var icons: [FinderIcon] = []
            for (i, nameDesc) in names.enumerated() where i < positions.count {
                guard let name = nameDesc.stringValue else { continue }
                let p = positions[i].listItems
                guard p.count == 2 else { continue }
                icons.append(FinderIcon(name: name, x: p[0].doubleValue, y: p[1].doubleValue))
            }
            windows.append(FinderWindowState(path: path, bounds: bounds, isIconView: isIconView, icons: icons))
        }
        return windows
    }

    /// Ne replace que les fenêtres déjà ouvertes : retourne `false` si le dossier n'a pas de fenêtre.
    @discardableResult
    func restoreFinderWindow(_ window: FinderWindowState, displays: [DisplaySnapshot]) throws -> Bool {
        let r = Geometry.fit(window.bounds.cgRect, in: displays)
        let bounds = [Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.maxX.rounded()), Int(r.maxY.rounded())]
        let icons = window.isIconView ? window.icons : []
        let result = try call("restorefinderwindow",
                     NSAppleEventDescriptor(string: window.path),
                     .list(ints: bounds),
                     .list(strings: icons.map(\.name)),
                     .list(ints: icons.map { Int($0.x.rounded()) }),
                     .list(ints: icons.map { Int($0.y.rounded()) }))
        return result.booleanValue
    }

    // MARK: Appel de gestionnaire AppleScript

    private func call(_ handler: String, _ args: NSAppleEventDescriptor...) throws -> NSAppleEventDescriptor {
        let params = NSAppleEventDescriptor.list()
        for arg in args { params.insert(arg, at: 0) } // 0 = ajout en fin de liste
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: .currentProcess(),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        event.setDescriptor(params, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result: NSAppleEventDescriptor? = script.executeAppleEvent(event, error: &error)
        if let error {
            throw BridgeError.script(code: (error[NSAppleScript.errorNumber] as? Int) ?? 0,
                                     message: (error[NSAppleScript.errorMessage] as? String) ?? "inconnue")
        }
        guard let result else { throw BridgeError.unexpectedResult(handler) }
        return result
    }

    // MARK: Source AppleScript

    private static let source = """
    on readDesktop()
        tell application "Finder"
            set theNames to name of every item of desktop
            set thePositions to desktop position of every item of desktop
        end tell
        return {theNames, thePositions}
    end readDesktop

    on restoreDesktop(theNames, xs, ys)
        set moved to 0
        tell application "Finder"
            try
                set arrangement of icon view options of window of desktop to not arranged
            end try
            repeat with i from 1 to count of theNames
                set n to item i of theNames
                set p to {item i of xs, item i of ys}
                try
                    set desktop position of item n of desktop to p
                    set moved to moved + 1
                on error
                    try
                        set desktop position of disk n to p
                        set moved to moved + 1
                    end try
                end try
            end repeat
        end tell
        return moved
    end restoreDesktop

    on readFinderWindows(maxIcons)
        set res to {}
        tell application "Finder"
            -- Pas de « repeat with w in every Finder window » : le Finder y lit les éléments du dossier affiché.
            repeat with i from 1 to count of Finder windows
                try
                    set w to Finder window i
                    set t to target of w
                    set p to POSIX path of (t as alias)
                    set b to bounds of w
                    set isIcon to ((current view of w) is icon view)
                    set theNames to {}
                    set thePositions to {}
                    if isIcon then
                        if (count of items of t) ≤ maxIcons then
                            set theNames to name of every item of t
                            set thePositions to position of every item of t
                        end if
                    end if
                    set end of res to {p, b, isIcon, theNames, thePositions}
                end try
            end repeat
        end tell
        return res
    end readFinderWindows

    on restoreFinderWindow(p, b, theNames, xs, ys)
        tell application "Finder"
            set f to (POSIX file p) as alias
            set w to missing value
            repeat with i from 1 to count of Finder windows
                try
                    set x to Finder window i
                    if (POSIX path of ((target of x) as alias)) is p then set w to x
                end try
            end repeat
            if w is missing value then return false
            set bounds of w to b
            if (count of theNames) > 0 then
                try
                    if (current view of w) is icon view then set arrangement of icon view options of w to not arranged
                end try
                repeat with i from 1 to count of theNames
                    try
                        set position of item (item i of theNames) of f to {item i of xs, item i of ys}
                    end try
                end repeat
            end if
        end tell
        return true
    end restoreFinderWindow
    """
}

extension NSAppleEventDescriptor {
    /// Éléments d'une liste AppleScript (vide si le descripteur n'est pas une liste).
    var listItems: [NSAppleEventDescriptor] {
        guard descriptorType == typeAEList else { return [] }
        let count = numberOfItems
        guard count > 0 else { return [] }
        return (1...count).compactMap { atIndex($0) }
    }

    static func list(strings: [String]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for s in strings { list.insert(NSAppleEventDescriptor(string: s), at: 0) }
        return list
    }

    static func list(ints: [Int]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for v in ints {
            let clamped = Int32(clamping: v)
            list.insert(NSAppleEventDescriptor(int32: clamped), at: 0)
        }
        return list
    }
}
