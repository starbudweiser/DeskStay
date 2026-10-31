// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeskStay",
    platforms: [.macOS(.v14)],
    targets: [
        // Logique pure (sans AppKit) : modèles, géométrie, fusion, persistance. Testable.
        .target(name: "DeskStayCore"),
        // Application barre de menus : Finder (AppleScript), fenêtres (Accessibilité), masquage.
        .executableTarget(name: "DeskStay", dependencies: ["DeskStayCore"]),
        .testTarget(name: "DeskStayCoreTests", dependencies: ["DeskStayCore"]),
    ]
)
