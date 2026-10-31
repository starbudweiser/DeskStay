import Foundation

/// Clé identifiant une combinaison d'écrans (indépendante de l'ordre et de la résolution).
public enum DisplayKey {
    public static func make(_ displays: [DisplaySnapshot]) -> String {
        Array(Set(displays.map(\.id))).sorted().joined(separator: "|")
    }
}

public enum Merge {
    /// Par défaut, une icône absente au moment de la mémorisation garde sa position enregistrée.
    /// `purgeMissing` oublie les icônes absentes.
    public static func desktopIcons(old: [DesktopIcon], new: [DesktopIcon], purgeMissing: Bool) -> [DesktopIcon] {
        if purgeMissing { return new }
        let present = Set(new.map(\.name))
        return new + old.filter { !present.contains($0.name) }
    }

    /// Les fenêtres d'une app non ouverte au moment de la mémorisation sont conservées (sauf purge).
    public static func appWindows(old: [AppWindowState], new: [AppWindowState], purgeMissing: Bool) -> [AppWindowState] {
        if purgeMissing { return new }
        let presentApps = Set(new.map(\.bundleID))
        return new + old.filter { !presentApps.contains($0.bundleID) }
    }
}

extension Merge {
    /// Remplace les fenêtres enregistrées d'une seule application, sans toucher aux autres.
    public static func replaceApp(old: [AppWindowState], new: [AppWindowState], bundleID: String) -> [AppWindowState] {
        old.filter { $0.bundleID != bundleID } + new.filter { $0.bundleID == bundleID }
    }
}

public enum WindowMatcher {
    public struct Candidate: Equatable, Sendable {
        public var title: String
        public var index: Int

        public init(title: String, index: Int) {
            self.title = title
            self.index = index
        }
    }

    public struct Pair: Equatable, Sendable {
        public var saved: Int
        public var current: Int

        public init(saved: Int, current: Int) {
            self.saved = saved
            self.current = current
        }
    }

    /// Associe les fenêtres enregistrées d'une app à ses fenêtres actuelles :
    /// 1) même titre non vide, 2) puis dans l'ordre des rangs pour le reste.
    public static func match(saved: [AppWindowState], current: [Candidate]) -> [Pair] {
        var usedSaved = Set<Int>()
        var usedCurrent = Set<Int>()
        var pairs: [Pair] = []

        for (si, state) in saved.enumerated() where !state.title.isEmpty {
            if let ci = current.indices.first(where: { !usedCurrent.contains($0) && current[$0].title == state.title }) {
                usedSaved.insert(si)
                usedCurrent.insert(ci)
                pairs.append(Pair(saved: si, current: ci))
            }
        }

        let restSaved = saved.indices.filter { !usedSaved.contains($0) }.sorted { saved[$0].index < saved[$1].index }
        let restCurrent = current.indices.filter { !usedCurrent.contains($0) }.sorted { current[$0].index < current[$1].index }
        for (si, ci) in zip(restSaved, restCurrent) {
            pairs.append(Pair(saved: si, current: ci))
        }
        return pairs
    }
}

public enum ArrangementSelector {
    /// Choix pour une restauration automatique :
    /// 1) l'arrangement actif s'il correspond aux écrans branchés,
    /// 2) sinon le plus récent qui correspond,
    /// 3) sinon l'arrangement actif (adapté aux écrans présents).
    public static func forAutoRestore(_ arrangements: [Arrangement], activeID: UUID?, displayKey: String) -> Arrangement? {
        let active = arrangements.first { $0.id == activeID }
        if let active, active.displayKey == displayKey { return active }
        if let match = arrangements.filter({ $0.displayKey == displayKey }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return match
        }
        return active
    }
}

public enum ArrangementName {
    public static let maxLength = 60

    /// Nettoie un nom saisi : retours à la ligne et caractères de contrôle retirés, longueur bornée.
    public static func sanitize(_ raw: String) -> String? {
        let flattened = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}
