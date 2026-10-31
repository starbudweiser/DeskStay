import CoreGraphics
import Foundation

/// Rectangle sérialisable (coordonnées Quartz globales : origine en haut à gauche de l'écran principal).
public struct CodableRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y),
                  width: Double(rect.size.width), height: Double(rect.size.height))
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Point exprimé en fraction (0…1) de la largeur / hauteur d'un écran.
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Écran actif au moment de la capture ou de la restauration.
public struct DisplaySnapshot: Equatable, Sendable {
    /// Identifiant stable (UUID de l'écran fourni par macOS).
    public var id: String
    /// Cadre global Quartz (origine en haut à gauche).
    public var frame: CGRect
    public var isMain: Bool

    public init(id: String, frame: CGRect, isMain: Bool) {
        self.id = id
        self.frame = frame
        self.isMain = isMain
    }
}

/// Icône du Bureau : position relative à l'écran qui la contient.
public struct DesktopIcon: Codable, Equatable, Sendable {
    public var name: String
    public var displayID: String
    public var position: NormalizedPoint

    public init(name: String, displayID: String, position: NormalizedPoint) {
        self.name = name
        self.displayID = displayID
        self.position = position
    }
}

/// Icône dans une fenêtre Finder : position brute dans la fenêtre (la taille de fenêtre est restaurée aussi).
public struct FinderIcon: Codable, Equatable, Sendable {
    public var name: String
    public var x: Double
    public var y: Double

    public init(name: String, x: Double, y: Double) {
        self.name = name
        self.x = x
        self.y = y
    }
}

public struct FinderWindowState: Codable, Equatable, Sendable {
    /// Chemin POSIX du dossier affiché.
    public var path: String
    /// Cadre global de la fenêtre.
    public var bounds: CodableRect
    public var isIconView: Bool
    public var icons: [FinderIcon]

    public init(path: String, bounds: CodableRect, isIconView: Bool, icons: [FinderIcon]) {
        self.path = path
        self.bounds = bounds
        self.isIconView = isIconView
        self.icons = icons
    }
}

/// Fenêtre d'application : cadre relatif à l'écran qui contient son centre.
public struct AppWindowState: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var title: String
    /// Rang de la fenêtre parmi les fenêtres standard de l'app au moment de la capture.
    public var index: Int
    public var displayID: String
    public var displayWidth: Double
    public var displayHeight: Double
    /// Origine relative à l'origine de l'écran, taille en points.
    public var relativeFrame: CodableRect

    public init(bundleID: String, appName: String, title: String, index: Int,
                displayID: String, displayWidth: Double, displayHeight: Double,
                relativeFrame: CodableRect) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.index = index
        self.displayID = displayID
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.relativeFrame = relativeFrame
    }
}

public struct Arrangement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Combinaison d'écrans présente lors de la dernière mémorisation (voir `DisplayKey`).
    public var displayKey: String
    public var desktopIcons: [DesktopIcon]
    public var finderWindows: [FinderWindowState]
    public var appWindows: [AppWindowState]

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date = Date(),
                displayKey: String = "", desktopIcons: [DesktopIcon] = [],
                finderWindows: [FinderWindowState] = [], appWindows: [AppWindowState] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.displayKey = displayKey
        self.desktopIcons = desktopIcons
        self.finderWindows = finderWindows
        self.appWindows = appWindows
    }
}

/// Ce que mémoriser / restaurer concerne : icônes du Bureau (type DIM) et/ou fenêtres (type Stay).
public struct Parts: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let icons = Parts(rawValue: 1)
    public static let finderWindows = Parts(rawValue: 2)
    public static let appWindows = Parts(rawValue: 4)
    public static let windows: Parts = [.finderWindows, .appWindows]
    public static let all: Parts = [.icons, .finderWindows, .appWindows]
}

public struct Settings: Codable, Equatable, Sendable {
    public var activeArrangementID: UUID?
    /// Aucune restauration automatique par défaut : tout se fait à la demande.
    public var restoreOnDisplayChange = false
    public var restoreOnWake = false
    public var restoreAtLaunch = false
    /// Applications dont les fenêtres ne sont jamais mémorisées ni déplacées (« Ne pas déplacer »).
    public var excludedApps: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case activeArrangementID, restoreOnDisplayChange, restoreOnWake, restoreAtLaunch, excludedApps
    }

    /// Décodage tolérant : une clé absente (fichier d'une version antérieure) prend sa valeur par défaut.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeArrangementID = try c.decodeIfPresent(UUID.self, forKey: .activeArrangementID)
        restoreOnDisplayChange = try c.decodeIfPresent(Bool.self, forKey: .restoreOnDisplayChange) ?? false
        restoreOnWake = try c.decodeIfPresent(Bool.self, forKey: .restoreOnWake) ?? false
        restoreAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .restoreAtLaunch) ?? false
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
    }
}

public struct StoreFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var settings: Settings
    public var arrangements: [Arrangement]

    public init(version: Int = StoreFile.currentVersion, settings: Settings = Settings(),
                arrangements: [Arrangement] = []) {
        self.version = version
        self.settings = settings
        self.arrangements = arrangements
    }
}
