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
    private(set) var lastStatus = L("ctl.ready")
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
            setStatus(L("ctl.saveFailed"))
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
            report.problems.append(L("ctl.noDisplay"))
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
                report.done.append(L("ctl.iconsCount", icons.count))
                capturedSomething = true
            } catch {
                report.problems.append(L("ctl.errDesktop", error.localizedDescription))
            }
        }

        if parts.contains(.finderWindows), onlyApp == nil {
            do {
                let windows = try finder().readFinderWindows()
                arrangement.finderWindows = windows
                report.done.append(L("ctl.finderCount", windows.count))
                capturedSomething = true
            } catch {
                report.problems.append(L("ctl.errFinderWindows", error.localizedDescription))
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
                report.done.append(L("ctl.appsCount", windows.count))
                capturedSomething = true
            } else {
                report.problems.append(L("ctl.errAppsTrust"))
            }
        }

        guard capturedSomething else {
            report.problems.append(L("ctl.nothingSaved"))
            setStatus(L("ctl.memorizeFailed"))
            return report
        }

        arrangement.displayKey = DisplayKey.make(displays)
        arrangement.updatedAt = Date()
        store.upsert(arrangement)
        if arrangementID == nil || settings.activeArrangementID == nil {
            store.data.settings.activeArrangementID = arrangement.id
        }
        if let error = persist() {
            report.problems.append(L("ctl.errSave", error.localizedDescription))
        }
        setStatus(L("ctl.memorized", report.done.joined(separator: ", ")))
        return report
    }

    private func defaultName() -> String {
        L("arr.defaultName", Date().formatted(date: .abbreviated, time: .shortened))
    }

    // MARK: Restaurer

    func restore(_ arrangement: Arrangement, parts: Parts = .all, onlyApp: String? = nil) -> Report {
        var report = Report()
        let displays = Displays.current()
        guard !displays.isEmpty else {
            report.problems.append(L("ctl.noDisplay"))
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
                        report.problems.append(L("ctl.folderMissing", window.path))
                        continue
                    }
                    do {
                        if try bridge.restoreFinderWindow(window, displays: displays) { ok += 1 } else { closed += 1 }
                    } catch {
                        report.problems.append(L("ctl.errWindow", window.path, error.localizedDescription))
                        if (error as? BridgeError)?.isAutomationDenied == true { break }
                    }
                }
                report.done.append(closed > 0 ? L("ctl.finderRestoredClosed", ok, closed) : L("ctl.finderRestored", ok))
            } catch {
                report.problems.append(L("ctl.errFinderWindows", error.localizedDescription))
            }
        }

        if parts.contains(.icons), !arrangement.desktopIcons.isEmpty {
            do {
                let bridge = try finder()
                // Le Finder met ~17 ms par icône : seules celles qui ne sont pas déjà en place sont déplacées.
                let current = Dictionary(try bridge.readDesktop(displays: displays).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                let toMove = arrangement.desktopIcons.filter { icon in
                    guard let now = current[icon.name], now.displayID == icon.displayID,
                          let display = Geometry.targetDisplay(id: icon.displayID, in: displays) else { return true }
                    let a = Geometry.denormalize(now.position, in: display.frame)
                    let b = Geometry.denormalize(icon.position, in: display.frame)
                    return hypot(a.x - b.x, a.y - b.y) >= 3 // le Finder arrondit à l'entier
                }
                let moved = toMove.isEmpty ? 0 : try bridge.restoreDesktop(toMove, displays: displays)
                report.done.append(L("ctl.iconsMoved", moved, arrangement.desktopIcons.count - toMove.count))
            } catch {
                report.problems.append(L("ctl.errDesktop", error.localizedDescription))
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
                    var text = L("ctl.appsRestored", r.moved)
                    if r.notFound > 0 { text += L("ctl.appsMissing", r.notFound) }
                    if r.fullScreen > 0 { text += L("ctl.appsFullScreen", r.fullScreen) }
                    report.done.append(text)
                    if r.failed > 0 {
                        report.problems.append(L("ctl.refused", r.failed, r.failures.joined(separator: " ; ")))
                    }
                } else {
                    report.problems.append(L("ctl.errAppsTrust"))
                }
            }
        }

        let summary = report.done.isEmpty ? L("ctl.nothingToRestore") : report.done.joined(separator: ", ")
        setStatus(L("ctl.restored", summary))
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
            setStatus(L("ctl.autoNone", reason))
            return
        }
        let report = restore(arrangement)
        if !report.problems.isEmpty {
            log.notice("Auto (\(reason, privacy: .public)) : \(report.problems.joined(separator: " | "), privacy: .public)")
        }
    }
}
