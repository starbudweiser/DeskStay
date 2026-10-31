import CoreGraphics
import XCTest
@testable import DeskStayCore

final class GeometryTests: XCTestCase {
    let main = DisplaySnapshot(id: "MAIN", frame: CGRect(x: 0, y: 0, width: 3440, height: 1440), isMain: true)
    let side = DisplaySnapshot(id: "SIDE", frame: CGRect(x: 3440, y: 49, width: 1080, height: 1920), isMain: false)

    func testNormalizeRoundTrip() {
        let rect = main.frame
        let p = CGPoint(x: 894, y: 73)
        let back = Geometry.denormalize(Geometry.normalize(p, in: rect), in: rect)
        XCTAssertEqual(back.x, p.x, accuracy: 0.001)
        XCTAssertEqual(back.y, p.y, accuracy: 0.001)
    }

    func testBottomRightStaysBottomRightAcrossResolutions() {
        let n = Geometry.normalize(CGPoint(x: 3400, y: 1400), in: main.frame)
        let p = Geometry.denormalize(n, in: CGRect(x: 0, y: 0, width: 1720, height: 720))
        XCTAssertEqual(p.x, 1700, accuracy: 0.5)
        XCTAssertEqual(p.y, 700, accuracy: 0.5)
    }

    func testNormalizeClampsAndHandlesDegenerateRect() {
        let n = Geometry.normalize(CGPoint(x: -50, y: 99_999), in: main.frame)
        XCTAssertEqual(n, NormalizedPoint(x: 0, y: 1))
        XCTAssertEqual(Geometry.normalize(CGPoint(x: 5, y: 5), in: .zero), NormalizedPoint(x: 0, y: 0))
        XCTAssertEqual(Geometry.clampUnit(.nan), 0)
        XCTAssertEqual(Geometry.clampUnit(.infinity), 0)
    }

    func testDisplayContainingOrNearest() {
        XCTAssertEqual(Geometry.display(containing: CGPoint(x: 3500, y: 500), in: [main, side])?.id, "SIDE")
        XCTAssertEqual(Geometry.display(containing: CGPoint(x: 3400, y: 30), in: [main, side])?.id, "MAIN")
        // Hors de tout écran : le plus proche.
        XCTAssertEqual(Geometry.display(containing: CGPoint(x: 5000, y: 1000), in: [main, side])?.id, "SIDE")
        XCTAssertNil(Geometry.display(containing: .zero, in: []))
    }

    func testTargetDisplayFallsBackToMain() {
        XCTAssertEqual(Geometry.targetDisplay(id: "SIDE", in: [main, side])?.id, "SIDE")
        XCTAssertEqual(Geometry.targetDisplay(id: "GONE", in: [side, main])?.id, "MAIN")
    }

    func testMapRelativeFrameSameSizeIsExact() {
        let rel = CGRect(x: -20, y: 100, width: 800, height: 600)
        let r = Geometry.mapRelativeFrame(rel, savedDisplaySize: side.frame.size, to: side.frame)
        XCTAssertEqual(r, CGRect(x: 3420, y: 149, width: 800, height: 600))
    }

    func testMapRelativeFrameScalesAndClamps() {
        let rel = CGRect(x: 3000, y: 1000, width: 2000, height: 600)
        let r = Geometry.mapRelativeFrame(rel, savedDisplaySize: main.frame.size, to: side.frame)
        XCTAssertLessThanOrEqual(r.width, side.frame.width)
        XCTAssertGreaterThanOrEqual(r.minX, side.frame.minX)
        XCTAssertLessThanOrEqual(r.maxX, side.frame.maxX)
        XCTAssertGreaterThanOrEqual(r.minY, side.frame.minY)
        XCTAssertLessThanOrEqual(r.maxY, side.frame.maxY)
    }

    func testFitPullsOffscreenWindowBack() {
        let r = Geometry.fit(CGRect(x: 6000, y: 3000, width: 500, height: 400), in: [main, side])
        XCTAssertTrue(side.frame.contains(r))
        let visible = CGRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertEqual(Geometry.fit(visible, in: [main, side]), visible)
    }
}

final class LogicTests: XCTestCase {
    func icon(_ name: String, _ x: Double = 0.5) -> DesktopIcon {
        DesktopIcon(name: name, displayID: "D", position: NormalizedPoint(x: x, y: 0.5))
    }

    func win(_ bundle: String, _ title: String, _ index: Int) -> AppWindowState {
        AppWindowState(bundleID: bundle, appName: bundle, title: title, index: index, displayID: "D",
                       displayWidth: 100, displayHeight: 100, relativeFrame: CodableRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testDisplayKeyIsOrderIndependent() {
        let a = DisplaySnapshot(id: "B", frame: .zero, isMain: true)
        let b = DisplaySnapshot(id: "A", frame: .zero, isMain: false)
        XCTAssertEqual(DisplayKey.make([a, b]), DisplayKey.make([b, a]))
        XCTAssertEqual(DisplayKey.make([a, b]), "A|B")
        XCTAssertEqual(DisplayKey.make([]), "")
    }

    func testMergeKeepsMissingIconsUnlessPurged() {
        let old = [icon("A", 0.1), icon("B", 0.2)]
        let new = [icon("A", 0.9)]
        let kept = Merge.desktopIcons(old: old, new: new, purgeMissing: false)
        XCTAssertEqual(kept.map(\.name), ["A", "B"])
        XCTAssertEqual(kept.first?.position.x, 0.9)
        XCTAssertEqual(Merge.desktopIcons(old: old, new: new, purgeMissing: true).map(\.name), ["A"])
    }

    func testMergeAppWindowsKeepsClosedApps() {
        let old = [win("app.a", "x", 0), win("app.b", "y", 0)]
        let new = [win("app.a", "z", 0)]
        XCTAssertEqual(Merge.appWindows(old: old, new: new, purgeMissing: false).map(\.title), ["z", "y"])
        XCTAssertEqual(Merge.appWindows(old: old, new: new, purgeMissing: true).map(\.title), ["z"])
    }

    func testMatcherPrefersTitlesThenIndex() {
        let saved = [win("a", "Doc 1", 0), win("a", "Doc 2", 1), win("a", "", 2)]
        let current = [WindowMatcher.Candidate(title: "Doc 2", index: 0),
                       WindowMatcher.Candidate(title: "Autre", index: 1),
                       WindowMatcher.Candidate(title: "Doc 1", index: 2)]
        let pairs = WindowMatcher.match(saved: saved, current: current)
        XCTAssertTrue(pairs.contains(WindowMatcher.Pair(saved: 0, current: 2)))
        XCTAssertTrue(pairs.contains(WindowMatcher.Pair(saved: 1, current: 0)))
        XCTAssertTrue(pairs.contains(WindowMatcher.Pair(saved: 2, current: 1)))
        XCTAssertEqual(pairs.count, 3)
    }

    func testMatcherNeverReusesAWindow() {
        let saved = [win("a", "Same", 0), win("a", "Same", 1), win("a", "Same", 2)]
        let current = [WindowMatcher.Candidate(title: "Same", index: 0)]
        let pairs = WindowMatcher.match(saved: saved, current: current)
        XCTAssertEqual(pairs, [WindowMatcher.Pair(saved: 0, current: 0)])
    }

    func testSelectorPriorities() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let active = Arrangement(name: "Actif", updatedAt: t0, displayKey: "K1")
        let recentK2 = Arrangement(name: "K2 récent", updatedAt: t1, displayKey: "K2")
        let oldK2 = Arrangement(name: "K2 ancien", updatedAt: t0, displayKey: "K2")
        let all = [active, oldK2, recentK2]
        XCTAssertEqual(ArrangementSelector.forAutoRestore(all, activeID: active.id, displayKey: "K1")?.name, "Actif")
        XCTAssertEqual(ArrangementSelector.forAutoRestore(all, activeID: active.id, displayKey: "K2")?.name, "K2 récent")
        XCTAssertEqual(ArrangementSelector.forAutoRestore(all, activeID: active.id, displayKey: "K3")?.name, "Actif")
        XCTAssertNil(ArrangementSelector.forAutoRestore(all, activeID: nil, displayKey: "K3"))
    }

    func testNameSanitize() {
        XCTAssertNil(ArrangementName.sanitize("   \n\t "))
        XCTAssertEqual(ArrangementName.sanitize("  Montage\nvidéo  "), "Montage vidéo")
        XCTAssertEqual(ArrangementName.sanitize(String(repeating: "x", count: 200))?.count, ArrangementName.maxLength)
    }

    func testSettingsDecodeToleratesMissingKeys() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"restoreOnWake": false}"#.utf8))
        XCTAssertFalse(s.restoreOnWake)
        XCTAssertFalse(s.restoreOnDisplayChange)
        XCTAssertFalse(s.restoreAtLaunch)
        XCTAssertTrue(s.animateIcons)
        XCTAssertEqual(s.excludedApps, [])
        XCTAssertNil(s.activeArrangementID)
    }

    func testSettingsIgnoreRemovedKeysAndKeepExclusions() throws {
        let raw = #"{"includeAppWindows": false, "restoreOnWake": true, "excludedApps": ["app.x"]}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(raw.utf8))
        XCTAssertTrue(s.restoreOnWake)
        XCTAssertEqual(s.excludedApps, ["app.x"])
    }

    func testReplaceAppTouchesOnlyThatApp() {
        let old = [win("app.a", "x", 0), win("app.b", "y", 0), win("app.a", "x2", 1)]
        let new = [win("app.a", "z", 0), win("app.c", "ignorée", 0)]
        let merged = Merge.replaceApp(old: old, new: new, bundleID: "app.a")
        XCTAssertEqual(merged.map(\.title), ["y", "z"])
        XCTAssertEqual(Merge.replaceApp(old: old, new: [], bundleID: "app.a").map(\.title), ["y"])
    }

    func testPartsCombinations() {
        XCTAssertTrue(Parts.all.contains(.icons))
        XCTAssertFalse(Parts.windows.contains(.icons))
        XCTAssertTrue(Parts.windows.contains(.finderWindows) && Parts.windows.contains(.appWindows))
    }
}

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeskStayTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func sample() -> Arrangement {
        Arrangement(name: "Bureau", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_100), displayKey: "A|B",
                    desktopIcons: [DesktopIcon(name: "Macintosh HD", displayID: "A", position: NormalizedPoint(x: 0.25, y: 0.05))],
                    finderWindows: [FinderWindowState(path: "/tmp/", bounds: CodableRect(x: 1, y: 2, width: 3, height: 4),
                                                      isIconView: true, icons: [FinderIcon(name: "a", x: 10, y: 20)])])
    }

    func testCreateSaveAndReload() throws {
        let store = ArrangementStore(directory: dir)
        XCTAssertEqual(try store.load(), .created)
        let a = sample()
        store.upsert(a)
        store.data.settings.activeArrangementID = a.id
        try store.save()

        let reloaded = ArrangementStore(directory: dir)
        XCTAssertEqual(try reloaded.load(), .loaded)
        XCTAssertEqual(reloaded.data, store.data)
    }

    func testSecondSaveKeepsBackup() throws {
        let store = ArrangementStore(directory: dir)
        try store.load()
        store.upsert(sample())
        try store.save()
        store.data.arrangements[0].name = "Modifié"
        try store.save()
        let backup = try JSONDecoder.isoDecoder.decode(StoreFile.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.arrangements.first?.name, "Bureau")
    }

    func testCorruptFileIsSetAsideNotLost() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("arrangements.json")
        try Data("{ pas du json".utf8).write(to: file)
        let store = ArrangementStore(directory: dir)
        guard case .recoveredFromCorrupt(let name) = try store.load() else {
            return XCTFail("Le fichier corrompu aurait dû être mis de côté")
        }
        let kept = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        XCTAssertEqual(kept, "{ pas du json")
        XCTAssertFalse(store.isReadOnly)
    }

    func testNewerVersionIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("arrangements.json")
        let original = #"{"version": 99, "settings": {}, "arrangements": []}"#
        try Data(original.utf8).write(to: file)
        let store = ArrangementStore(directory: dir)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(store.isReadOnly)
        XCTAssertThrowsError(try store.save()) { XCTAssertEqual($0 as? StoreError, .readOnly) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }

    func testRemoveActiveSelectsAnother() throws {
        let store = ArrangementStore(directory: dir)
        let a = Arrangement(name: "A")
        let b = Arrangement(name: "B")
        store.upsert(a)
        store.upsert(b)
        store.data.settings.activeArrangementID = a.id
        store.remove(id: a.id)
        XCTAssertEqual(store.data.settings.activeArrangementID, b.id)
        store.remove(id: b.id)
        XCTAssertNil(store.data.settings.activeArrangementID)
    }
}

private extension JSONDecoder {
    static var isoDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
