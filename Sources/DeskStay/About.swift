import AppKit
import DeskStayCore

/// Fenêtre « À propos » : version, auteurs, licence. Textes dans les fichiers de langue (L).
@MainActor
enum About {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let lines = [L("about.tagline"), L("about.authors"), L("about.license"), L("about.disclaimer"), L("about.credit")]
        let credits = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            credits.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""),
                                              attributes: [.font: i == 1 ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11),
                                                           .foregroundColor: NSColor.labelColor,
                                                           .paragraphStyle: paragraph]))
        }
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "DeskStay",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Starbudweiser",
        ])
    }
}
