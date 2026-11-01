// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeskStay",
    platforms: [.macOS(.v14)],
    products: [
        // Le binaire (et donc le paquet .app) porte le nom de l'appli, règle Socle « Nom de l'appli ».
        .executable(name: "DeSKSTAY", targets: ["DeskStay"]),
    ],
    targets: [
        // Logique pure (sans AppKit) : modèles, géométrie, fusion, persistance. Testable.
        .target(name: "DeskStayCore"),
        // Application barre de menus : Finder (AppleScript), fenêtres (Accessibilité), masquage.
        .executableTarget(name: "DeskStay", dependencies: ["DeskStayCore"]),
        .testTarget(name: "DeskStayCoreTests", dependencies: ["DeskStayCore"]),
    ]
)
