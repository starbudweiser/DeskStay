import AppKit
import DeskStayCore
import os

/// Orchestration : mémoriser / restaurer un arrangement, restauration automatique, persistance.
@MainActor
final class Controller {
    struct Report {
        var done: [String] = []
        var problems: [String] = []
    }

    let store: ArrangementStore
    let hider = IconHider()
    private(set) var lastStatus = "Prêt"
    private var finderBridge: FinderBridge?
    private var pendingAutoRestore: Task<Void, Never>?
    private let log = Logger(subsystem: "com.stephan.deskstay", category: "controller")

    init(store: ArrangementStore) {
        self.store = store
    }

    var settings: Settings { store.data.settings }

    var activeArrangement: Arrangement? { store.arrangement(id: settings.activeArrangementID) }

    func updateSettings(_ change: (inout Settings) -> Void) -> Error? {
        change(&store.data.settings)
        return persist()
    }

    @discardableResult
    func persist() -> Error? {
        do {
            try store.save()
            return nil
        } catch {
            log.error("Enregistrement impossible : \(error.localizedDescription, privacy: .public)")
            setStatus("Échec d'enregistrement")
            return error
        }
    }

    private func finder() throws -> FinderBridge {
        if let finderBridge { return finderBridge }
        let bridge = try FinderBridge()
        finderBridge = bridge
        return bridge
    }

    private func setStatus(_ text: String) {
        let time = Date().formatted(date: .omitted, time: .shortened)
        lastStatus = "\(time) — \(text)"
        log.info("\(text, privacy: .public)")
    }

    // MARK: Mémoriser

    /// `arrangementID == nil` : crée un arrangement (nommé `newName`, sinon daté) et le rend actif.
    /// `onlyApp` : limite la partie « fenêtres d'applications » à une seule application (identifiant de paquet).
    func memorize(arrangementID: UUID?, newName: String?, purgeMissing: Bool,
                  parts: Parts = .all, onlyApp: String? = nil) -> Report {
        var report = Report()
        let displays = Displays.current()
        guard !displays.isEmpty else {
            report.problems.append("Aucun écran détecté.")
            return report
        }
        var arrangement: Arrangement
        if let id = arrangementID, let existing = store.arrangement(id: id) {
            arrangement = existing
        } else {
            arrangement = Arrangement(name: newName ?? defaultName())
        }

        var capturedSomething = false

        if parts.contains(.icons) {
            do {
                let icons = try finder().readDesktop(displays: displays)
                arrangement.desktopIcons = Merge.desktopIcons(old: arrangement.desktopIcons, new: icons, purgeMissing: purgeMissing)
                report.done.append("\(icons.count) icônes")
                capturedSomething = true
            } catch {
                report.problems.append("Bureau : \(error.localizedDescription)")
            }
        }

        if parts.contains(.finderWindows), onlyApp == nil {
            do {
                let windows = try finder().readFinderWindows()
                arrangement.finderWindows = windows
                report.done.append("\(windows.count) fenêtres Finder")
                capturedSomething = true
            } catch {
                report.problems.append("Fenêtres Finder : \(error.localizedDescription)")
            }
        }

        if parts.contains(.appWindows) {
            if WindowBridge.isTrusted {
                let excluded = Set(settings.excludedApps)
                let apps = WindowBridge.candidateApps().filter { app in
                    guard let id = app.bundleIdentifier else { return false }
                    return onlyApp.map { $0 == id } ?? !excluded.contains(id)
                }
                let windows = WindowBridge.capture(displays: displays, apps: apps)
                if let onlyApp {
                    arrangement.appWindows = Merge.replaceApp(old: arrangement.appWindows, new: windows, bundleID: onlyApp)
                } else {
                    arrangement.appWindows = Merge.appWindows(old: arrangement.appWindows, new: windows, purgeMissing: purgeMissing)
                }
                report.done.append("\(windows.count) fenêtres d'apps")
                capturedSomething = true
            } else {
                report.problems.append("Fenêtres d'applications : accès Accessibilité non accordé.")
            }
        }

        guard capturedSomething else {
            report.problems.append("Rien n'a été enregistré.")
            setStatus("Mémorisation échouée")
            return report
        }

        arrangement.displayKey = DisplayKey.make(displays)
        arrangement.updatedAt = Date()
        store.upsert(arrangement)
        if arrangementID == nil || settings.activeArrangementID == nil {
            store.data.settings.activeArrangementID = arrangement.id
        }
        if let error = persist() {
            report.problems.append("Enregistrement : \(error.localizedDescription)")
        }
        setStatus("Mémorisé « \(arrangement.name) » : " + report.done.joined(separator: ", "))
        return report
    }

    private func defaultName() -> String {
        "Arrangement \(Date().formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: Restaurer

    func restore(_ arrangement: Arrangement, parts: Parts = .all, onlyApp: String? = nil) -> Report {
        var report = Report()
        let displays = Displays.current()
        guard !displays.isEmpty else {
            report.problems.append("Aucun écran détecté.")
            return report
        }

        // Seules les fenêtres Finder déjà ouvertes sont replacées : aucune n'est rouverte.
        if parts.contains(.finderWindows), onlyApp == nil, !arrangement.finderWindows.isEmpty {
            do {
                let bridge = try finder()
                var ok = 0
                var closed = 0
                for window in arrangement.finderWindows {
                    guard FileManager.default.fileExists(atPath: window.path) else {
                        report.problems.append("Dossier introuvable : \(window.path)")
                        continue
                    }
                    do {
                        if try bridge.restoreFinderWindow(window, displays: displays) { ok += 1 } else { closed += 1 }
                    } catch {
                        report.problems.append("Fenêtre \(window.path) : \(error.localizedDescription)")
                        if (error as? BridgeError)?.isAutomationDenied == true { break }
                    }
                }
                report.done.append("\(ok) fenêtres Finder" + (closed > 0 ? " (\(closed) fermées, ignorées)" : ""))
            } catch {
                report.problems.append("Fenêtres Finder : \(error.localizedDescription)")
            }
        }

        if parts.contains(.icons), !arrangement.desktopIcons.isEmpty {
            do {
                let bridge = try finder()
                let moved = settings.animateIcons
                    ? try IconAnimator.restore(arrangement.desktopIcons, displays: displays, bridge: bridge)
                    : try bridge.restoreDesktop(arrangement.desktopIcons, displays: displays)
                report.done.append("\(moved)/\(arrangement.desktopIcons.count) icônes")
            } catch {
                report.problems.append("Bureau : \(error.localizedDescription)")
            }
        }

        if parts.contains(.appWindows) {
            let excluded = Set(settings.excludedApps)
            let saved = arrangement.appWindows.filter { state in
                onlyApp.map { $0 == state.bundleID } ?? !excluded.contains(state.bundleID)
            }
            if !saved.isEmpty {
                if WindowBridge.isTrusted {
                    let r = WindowBridge.restore(saved, displays: displays)
                    var text = "\(r.moved) fenêtres d'apps"
                    if r.notFound > 0 { text += " (\(r.notFound) absentes)" }
                    if r.fullScreen > 0 { text += " (\(r.fullScreen) en plein écran, laissées)" }
                    report.done.append(text)
                    if r.failed > 0 {
                        report.problems.append("\(r.failed) fenêtre(s) ont refusé d'être déplacées : " + r.failures.joined(separator: " ; "))
                    }
                } else {
                    report.problems.append("Fenêtres d'applications : accès Accessibilité non accordé.")
                }
            }
        }

        let summary = report.done.isEmpty ? "rien à restaurer" : report.done.joined(separator: ", ")
        setStatus("Restauré « \(arrangement.name) » : \(summary)")
        return report
    }

    // MARK: Restauration automatique

    /// Regroupe les événements rapprochés (ex. plusieurs notifications d'écran) en une seule restauration.
    func scheduleAutoRestore(reason: String, after seconds: Double) {
        pendingAutoRestore?.cancel()
        pendingAutoRestore = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.autoRestore(reason: reason)
        }
    }

    private func autoRestore(reason: String) {
        let key = DisplayKey.make(Displays.current())
        guard let arrangement = ArrangementSelector.forAutoRestore(store.data.arrangements,
                                                                    activeID: settings.activeArrangementID,
                                                                    displayKey: key) else {
            setStatus("Auto (\(reason)) : aucun arrangement")
            return
        }
        let report = restore(arrangement)
        if !report.problems.isEmpty {
            log.notice("Auto (\(reason, privacy: .public)) : \(report.problems.joined(separator: " | "), privacy: .public)")
        }
    }
}
