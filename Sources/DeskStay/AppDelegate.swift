import AppKit
import DeskStayCore
import ServiceManagement

/// Élément de menu exécutant une closure.
final class ClosureMenuItem: NSMenuItem {
    private var handler: (@MainActor () -> Void)?

    convenience init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                     handler: @escaping @MainActor () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.handler = handler
        self.target = self
        self.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
    }

    @MainActor @objc private func fire() { // AppKit appelle les actions de menu sur le thread principal
        handler?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private(set) var controller: Controller?
    private let menu = NSMenu()
    #if DESKSTAY_SELFTEST
    var dataDirectoryOverride: URL?
    #endif

    // MARK: Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        var directory = Self.dataDirectory()
        #if DESKSTAY_SELFTEST
        if let dataDirectoryOverride { directory = dataDirectoryOverride }
        #endif
        let store = ArrangementStore(directory: directory)
        do {
            if case .recoveredFromCorrupt(let name) = try store.load() {
                showAlert("Fichier de données illisible",
                          "Il a été conservé sous le nom « \(name) » et un nouveau fichier a été créé.")
            }
        } catch {
            showAlert("Impossible de charger les données", error.localizedDescription)
        }
        let controller = Controller(store: store)
        self.controller = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "DeskStay") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "DS"
        }
        menu.delegate = self
        item.menu = menu
        statusItem = item

        observeSystemEvents()
        if controller.settings.restoreAtLaunch {
            controller.scheduleAutoRestore(reason: "ouverture", after: 4)
        }
    }

    private static func dataDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DeskStay", isDirectory: true)
    }

    // MARK: Événements système

    private func observeSystemEvents() {
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(didUnlock),
                                                            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func screensChanged() {
        guard let controller else { return }
        controller.hider.refresh()
        if controller.settings.restoreOnDisplayChange {
            controller.scheduleAutoRestore(reason: "écrans", after: 2.5)
        }
    }

    @objc private func didWake() {
        guard let controller, controller.settings.restoreOnWake else { return }
        controller.scheduleAutoRestore(reason: "réveil", after: 3)
    }

    @objc private func didUnlock() {
        guard let controller, controller.settings.restoreOnWake else { return }
        controller.scheduleAutoRestore(reason: "déverrouillage", after: 2)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let c = controller else { return }
        let displays = Displays.current()
        let key = DisplayKey.make(displays)
        let known = c.store.data.arrangements.contains { $0.displayKey == key }

        menu.addItem(info("\(displays.count) écran(s) — configuration \(known ? "mémorisée" : "non mémorisée")"))
        menu.addItem(info(c.lastStatus))
        if c.store.isReadOnly { menu.addItem(info("⚠︎ Lecture seule : données non chargées")) }
        menu.addItem(.separator())

        if let active = c.activeArrangement {
            let id = active.id
            menu.addItem(ClosureMenuItem("Restaurer « \(active.name) »", key: "r") { [weak self] in self?.restore(id) })
            menu.addItem(ClosureMenuItem("Mémoriser dans « \(active.name) »", key: "m") { [weak self] in
                self?.memorize(into: id, purge: false)
            })
            let purge = ClosureMenuItem("Mémoriser et oublier les absents", key: "m", modifiers: [.command, .option]) { [weak self] in
                self?.memorize(into: id, purge: true)
            }
            purge.isAlternate = true
            menu.addItem(purge)
        } else {
            menu.addItem(info("Aucun arrangement actif"))
        }
        menu.addItem(ClosureMenuItem("Nouvel arrangement…", key: "n") { [weak self] in self?.newArrangement() })
        menu.addItem(arrangementsItem(currentKey: key))
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(c.hider.isHidden ? "Afficher les icônes du Bureau" : "Masquer les icônes du Bureau",
                                     key: "h") { [weak self] in self?.controller?.hider.toggle() })
        menu.addItem(.separator())
        menu.addItem(includeItem())
        menu.addItem(autoRestoreItem())
        menu.addItem(loginItem())
        if !WindowBridge.isTrusted {
            menu.addItem(ClosureMenuItem("Autoriser l'accès Accessibilité…") { [weak self] in self?.openAccessibility() })
        }
        menu.addItem(ClosureMenuItem("Ouvrir le dossier des données") { [weak self] in
            guard let dir = self?.controller?.store.directory else { return }
            NSWorkspace.shared.open(dir)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quitter DeskStay", key: "q") { NSApp.terminate(nil) })
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func arrangementsItem(currentKey: String) -> NSMenuItem {
        let root = NSMenuItem(title: "Arrangements", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        guard let c = controller else { return root }
        let all = c.store.data.arrangements.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if all.isEmpty { sub.addItem(info("Aucun")) }
        for a in all {
            let id = a.id
            let item = NSMenuItem(title: a.name, action: nil, keyEquivalent: "")
            item.state = a.id == c.settings.activeArrangementID ? .on : .off
            let actions = NSMenu()
            var summary = "\(a.desktopIcons.count) icônes · \(a.finderWindows.count) Finder · \(a.appWindows.count) fenêtres"
            if a.displayKey == currentKey { summary += " · ces écrans" }
            actions.addItem(info(summary))
            actions.addItem(.separator())
            actions.addItem(ClosureMenuItem("Restaurer") { [weak self] in self?.restore(id) })
            actions.addItem(ClosureMenuItem("Mémoriser ici") { [weak self] in self?.memorize(into: id, purge: false) })
            actions.addItem(ClosureMenuItem("Définir comme actif") { [weak self] in
                guard let self, let c = self.controller else { return }
                if let error = c.updateSettings({ $0.activeArrangementID = id }) { self.showError(error) }
            })
            actions.addItem(ClosureMenuItem("Renommer…") { [weak self] in self?.rename(id) })
            actions.addItem(ClosureMenuItem("Supprimer…") { [weak self] in self?.delete(id) })
            item.submenu = actions
            sub.addItem(item)
        }
        root.submenu = sub
        return root
    }

    private func toggle(_ title: String, _ value: Bool, _ change: @escaping @MainActor (inout Settings) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title) { [weak self] in
            guard let self, let c = self.controller else { return }
            if let error = c.updateSettings(change) { self.showError(error) }
        }
        item.state = value ? .on : .off
        return item
    }

    private func includeItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Inclure", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        guard let s = controller?.settings else { return root }
        sub.addItem(toggle("Icônes du Bureau", s.includeDesktopIcons) { $0.includeDesktopIcons.toggle() })
        sub.addItem(toggle("Fenêtres Finder", s.includeFinderWindows) { $0.includeFinderWindows.toggle() })
        sub.addItem(toggle("Fenêtres d'applications", s.includeAppWindows) { $0.includeAppWindows.toggle() })
        root.submenu = sub
        return root
    }

    private func autoRestoreItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Restauration automatique", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        guard let s = controller?.settings else { return root }
        sub.addItem(toggle("Quand les écrans changent", s.restoreOnDisplayChange) { $0.restoreOnDisplayChange.toggle() })
        sub.addItem(toggle("Au réveil et au déverrouillage", s.restoreOnWake) { $0.restoreOnWake.toggle() })
        sub.addItem(toggle("À l'ouverture de DeskStay", s.restoreAtLaunch) { $0.restoreAtLaunch.toggle() })
        root.submenu = sub
        return root
    }

    private func loginItem() -> NSMenuItem {
        let status = SMAppService.mainApp.status
        let item = ClosureMenuItem("Ouvrir à l'ouverture de session") { [weak self] in self?.toggleLogin() }
        item.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        return item
    }

    // MARK: Actions

    private func restore(_ id: UUID) {
        guard let c = controller, let a = c.store.arrangement(id: id) else { return }
        present(c.restore(a), title: "Restauration incomplète")
    }

    private func memorize(into id: UUID?, purge: Bool, newName: String? = nil) {
        guard let c = controller else { return }
        if c.settings.includeAppWindows, !WindowBridge.isTrusted { WindowBridge.requestTrust() }
        present(c.memorize(arrangementID: id, newName: newName, purgeMissing: purge), title: "Mémorisation incomplète")
    }

    private func newArrangement() {
        guard let name = askName(title: "Nouvel arrangement", message: "Mémorise la disposition actuelle sous ce nom.",
                                 initial: "") else { return }
        memorize(into: nil, purge: false, newName: name)
    }

    private func rename(_ id: UUID) {
        guard let c = controller, var a = c.store.arrangement(id: id),
              let name = askName(title: "Renommer", message: "", initial: a.name) else { return }
        a.name = name
        c.store.upsert(a)
        if let error = c.persist() { showError(error) }
    }

    private func delete(_ id: UUID) {
        guard let c = controller, let a = c.store.arrangement(id: id) else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Supprimer « \(a.name) » ?"
        alert.informativeText = "Cette action est définitive (une copie de l'état précédent reste dans arrangements.json.bak)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        c.store.remove(id: id)
        if let error = c.persist() { showError(error) }
    }

    private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            showAlert("Ouverture à l'ouverture de session impossible", error.localizedDescription)
        }
    }

    private func openAccessibility() {
        WindowBridge.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Dialogues

    private func present(_ report: Controller.Report, title: String) {
        guard !report.problems.isEmpty else { return }
        var text = report.problems.prefix(8).joined(separator: "\n")
        if report.problems.count > 8 { text += "\n… et \(report.problems.count - 8) autre(s)." }
        if !report.done.isEmpty { text = "Fait : " + report.done.joined(separator: ", ") + "\n\n" + text }
        showAlert(title, text)
    }

    private func askName(title: String, message: String, initial: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        field.placeholderString = "Nom de l'arrangement"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let name = ArrangementName.sanitize(field.stringValue) else {
            showAlert("Nom invalide", "Le nom ne peut pas être vide.")
            return nil
        }
        return name
    }

    private func showError(_ error: Error) {
        showAlert("Erreur", error.localizedDescription)
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
