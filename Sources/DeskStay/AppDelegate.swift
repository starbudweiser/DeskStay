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
                showAlert(L("dialog.corruptTitle"), L("dialog.corruptInfo", name))
            }
        } catch {
            showAlert(L("dialog.loadFailed"), error.localizedDescription)
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
            controller.scheduleAutoRestore(reason: L("reason.launch"), after: 4)
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
            controller.scheduleAutoRestore(reason: L("reason.displays"), after: 2.5)
        }
    }

    @objc private func didWake() {
        guard let controller, controller.settings.restoreOnWake else { return }
        controller.scheduleAutoRestore(reason: L("reason.wake"), after: 3)
    }

    @objc private func didUnlock() {
        guard let controller, controller.settings.restoreOnWake else { return }
        controller.scheduleAutoRestore(reason: L("reason.unlock"), after: 2)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let c = controller else { return }
        let displays = Displays.current()
        let key = DisplayKey.make(displays)
        let known = c.store.data.arrangements.contains { $0.displayKey == key }

        menu.addItem(info(L(known ? "menu.displaysKnown" : "menu.displaysUnknown", displays.count)))
        menu.addItem(info(c.lastStatus))
        if c.store.isReadOnly { menu.addItem(info(L("menu.readOnly"))) }
        menu.addItem(.separator())

        let activeID = c.activeArrangement?.id
        menu.addItem(info(c.activeArrangement.map { L("menu.active", $0.name) } ?? L("menu.noActive")))
        menu.addItem(.separator())

        // Icônes du Bureau (type DIM)
        menu.addItem(.sectionHeader(title: L("menu.iconsHeader")))
        menu.addItem(ClosureMenuItem(L("menu.memorizeIcons")) { [weak self] in self?.memorize(into: activeID, purge: false, parts: .icons) })
        if let activeID {
            menu.addItem(ClosureMenuItem(L("menu.restoreIcons")) { [weak self] in self?.restore(activeID, parts: .icons) })
        }
        menu.addItem(ClosureMenuItem(L(c.hider.isHidden ? "menu.showIcons" : "menu.hideIcons"),
                                     key: "h") { [weak self] in self?.controller?.hider.toggle() })
        menu.addItem(.separator())

        // Fenêtres (type Stay)
        menu.addItem(.sectionHeader(title: L("menu.windowsHeader")))
        menu.addItem(ClosureMenuItem(L("menu.memorizeWindows")) { [weak self] in self?.memorize(into: activeID, purge: false, parts: .windows) })
        if let activeID {
            menu.addItem(ClosureMenuItem(L("menu.restoreWindows")) { [weak self] in self?.restore(activeID, parts: .windows) })
        }
        menu.addItem(applicationsItem(active: c.activeArrangement))
        menu.addItem(.separator())

        // Tout
        if let activeID {
            menu.addItem(ClosureMenuItem(L("menu.restoreAll"), key: "r") { [weak self] in self?.restore(activeID, parts: .all) })
        }
        menu.addItem(ClosureMenuItem(L("menu.memorizeAll"), key: "m") { [weak self] in self?.memorize(into: activeID, purge: false, parts: .all) })
        let purge = ClosureMenuItem(L("menu.memorizePurge"), key: "m", modifiers: [.command, .option]) { [weak self] in
            self?.memorize(into: activeID, purge: true, parts: .all)
        }
        purge.isAlternate = true
        menu.addItem(purge)
        menu.addItem(ClosureMenuItem(L("menu.newArrangement"), key: "n") { [weak self] in self?.newArrangement() })
        menu.addItem(arrangementsItem(currentKey: key))
        menu.addItem(.separator())
        menu.addItem(autoRestoreItem())
        menu.addItem(loginItem())
        if !WindowBridge.isTrusted {
            menu.addItem(ClosureMenuItem(L("menu.allowAccessibility")) { [weak self] in self?.openAccessibility() })
        }
        menu.addItem(ClosureMenuItem(L("menu.openData")) { [weak self] in
            guard let dir = self?.controller?.store.directory else { return }
            NSWorkspace.shared.open(dir)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("about.menu")) { About.show() })
        menu.addItem(ClosureMenuItem(L("menu.quit"), key: "q") { NSApp.terminate(nil) })
    }

    /// Largeur maximale d'une ligne d'information : c'est elle qui fixait la largeur de tout le menu.
    private static let infoLimit = 36

    /// Ligne d'information : raccourcie au milieu si besoin, le texte complet reste dans l'infobulle.
    private func info(_ text: String) -> NSMenuItem {
        var shown = text
        if text.count > Self.infoLimit {
            let keep = Self.infoLimit - 1
            shown = String(text.prefix(keep * 2 / 3)) + "…" + String(text.suffix(keep - keep * 2 / 3))
        }
        let item = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if shown != text { item.toolTip = text }
        return item
    }

    private func arrangementsItem(currentKey: String) -> NSMenuItem {
        let root = NSMenuItem(title: L("menu.arrangements"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        guard let c = controller else { return root }
        let all = c.store.data.arrangements.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if all.isEmpty { sub.addItem(info(L("arr.none"))) }
        for a in all {
            let id = a.id
            let item = NSMenuItem(title: a.name, action: nil, keyEquivalent: "")
            item.state = a.id == c.settings.activeArrangementID ? .on : .off
            let actions = NSMenu()
            var summary = L("arr.summary", a.desktopIcons.count, a.finderWindows.count, a.appWindows.count)
            if a.displayKey == currentKey { summary += L("arr.thisDisplays") }
            actions.addItem(info(summary))
            actions.addItem(.separator())
            actions.addItem(ClosureMenuItem(L("arr.restoreAll")) { [weak self] in self?.restore(id) })
            actions.addItem(ClosureMenuItem(L("arr.restoreIcons")) { [weak self] in self?.restore(id, parts: .icons) })
            actions.addItem(ClosureMenuItem(L("arr.restoreWindows")) { [weak self] in self?.restore(id, parts: .windows) })
            actions.addItem(.separator())
            actions.addItem(ClosureMenuItem(L("arr.memorizeAll")) { [weak self] in self?.memorize(into: id, purge: false) })
            actions.addItem(ClosureMenuItem(L("arr.memorizeIcons")) { [weak self] in self?.memorize(into: id, purge: false, parts: .icons) })
            actions.addItem(ClosureMenuItem(L("arr.memorizeWindows")) { [weak self] in self?.memorize(into: id, purge: false, parts: .windows) })
            actions.addItem(.separator())
            actions.addItem(ClosureMenuItem(L("arr.setActive")) { [weak self] in
                guard let self, let c = self.controller else { return }
                if let error = c.updateSettings({ $0.activeArrangementID = id }) { self.showError(error) }
            })
            actions.addItem(ClosureMenuItem(L("arr.rename")) { [weak self] in self?.rename(id) })
            actions.addItem(ClosureMenuItem(L("arr.delete")) { [weak self] in self?.delete(id) })
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

    /// Choix app par app : mémoriser / restaurer une seule application, ou l'exclure (« Ne pas déplacer »).
    private func applicationsItem(active: Arrangement?) -> NSMenuItem {
        let root = NSMenuItem(title: L("menu.applications"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        guard let c = controller else { return root }
        let excluded = Set(c.settings.excludedApps)
        let apps = WindowBridge.candidateApps().sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
        if apps.isEmpty { sub.addItem(info(L("apps.none"))) }
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? bundleID
            let isExcluded = excluded.contains(bundleID)
            let item = NSMenuItem(title: isExcluded ? L("apps.nameExcluded", name) : name, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            let saved = active?.appWindows.filter { $0.bundleID == bundleID }.count ?? 0
            actions.addItem(info(saved > 0 ? L("apps.saved", saved) : L("apps.noneSaved")))
            actions.addItem(.separator())
            let activeID = active?.id
            actions.addItem(ClosureMenuItem(L("apps.memorize")) { [weak self] in
                self?.memorize(into: activeID, purge: false, parts: .appWindows, onlyApp: bundleID)
            })
            if let activeID, saved > 0 {
                actions.addItem(ClosureMenuItem(L("apps.restore")) { [weak self] in
                    self?.restore(activeID, parts: .appWindows, onlyApp: bundleID)
                })
            }
            actions.addItem(toggle(L("apps.exclude"), isExcluded) {
                if let i = $0.excludedApps.firstIndex(of: bundleID) { $0.excludedApps.remove(at: i) } else { $0.excludedApps.append(bundleID) }
            })
            item.submenu = actions
            sub.addItem(item)
        }
        root.submenu = sub
        return root
    }

    private func autoRestoreItem() -> NSMenuItem {
        let root = NSMenuItem(title: L("menu.autoRestore"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        guard let s = controller?.settings else { return root }
        sub.addItem(toggle(L("auto.displays"), s.restoreOnDisplayChange) { $0.restoreOnDisplayChange.toggle() })
        sub.addItem(toggle(L("auto.wake"), s.restoreOnWake) { $0.restoreOnWake.toggle() })
        sub.addItem(toggle(L("auto.launch"), s.restoreAtLaunch) { $0.restoreAtLaunch.toggle() })
        root.submenu = sub
        return root
    }

    private func loginItem() -> NSMenuItem {
        let status = SMAppService.mainApp.status
        let item = ClosureMenuItem(L("menu.login")) { [weak self] in self?.toggleLogin() }
        item.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        return item
    }

    // MARK: Actions

    private func restore(_ id: UUID, parts: Parts = .all, onlyApp: String? = nil) {
        guard let c = controller, let a = c.store.arrangement(id: id) else { return }
        if parts.contains(.appWindows), !WindowBridge.isTrusted { WindowBridge.requestTrust() }
        present(c.restore(a, parts: parts, onlyApp: onlyApp), title: L("dialog.incompleteRestore"))
    }

    private func memorize(into id: UUID?, purge: Bool, newName: String? = nil, parts: Parts = .all, onlyApp: String? = nil) {
        guard let c = controller else { return }
        if parts.contains(.appWindows), !WindowBridge.isTrusted { WindowBridge.requestTrust() }
        present(c.memorize(arrangementID: id, newName: newName, purgeMissing: purge, parts: parts, onlyApp: onlyApp),
                title: L("dialog.incompleteMemorize"))
    }

    private func newArrangement() {
        guard let name = askName(title: L("dialog.newTitle"), message: L("dialog.newMessage"),
                                 initial: "") else { return }
        memorize(into: nil, purge: false, newName: name)
    }

    private func rename(_ id: UUID) {
        guard let c = controller, var a = c.store.arrangement(id: id),
              let name = askName(title: L("dialog.renameTitle"), message: "", initial: a.name) else { return }
        a.name = name
        c.store.upsert(a)
        if let error = c.persist() { showError(error) }
    }

    private func delete(_ id: UUID) {
        guard let c = controller, let a = c.store.arrangement(id: id) else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("dialog.deleteTitle", a.name)
        alert.informativeText = L("dialog.deleteInfo")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("dialog.delete"))
        alert.addButton(withTitle: L("dialog.cancel"))
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
            showAlert(L("dialog.loginFailed"), error.localizedDescription)
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
        if report.problems.count > 8 { text += "\n" + L("dialog.more", report.problems.count - 8) }
        if !report.done.isEmpty { text = L("dialog.done", report.done.joined(separator: ", ")) + "\n\n" + text }
        showAlert(title, text)
    }

    private func askName(title: String, message: String, initial: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("dialog.ok"))
        alert.addButton(withTitle: L("dialog.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        field.placeholderString = L("dialog.namePlaceholder")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let name = ArrangementName.sanitize(field.stringValue) else {
            showAlert(L("dialog.invalidName"), L("dialog.invalidNameInfo"))
            return nil
        }
        return name
    }

    private func showError(_ error: Error) {
        showAlert(L("dialog.error"), error.localizedDescription)
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
