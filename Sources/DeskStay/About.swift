import AppKit

/// Fenêtre « À propos » : version, auteurs, licence. Texte dans la langue du système (fr, en, es, it ; anglais sinon).
@MainActor
enum About {
    private struct Texts {
        let menu: String
        let tagline: String
        let authors: String
        let license: String
        let disclaimer: String
        let credit: String
    }

    private static let texts: [String: Texts] = [
        "fr": Texts(menu: "À propos de DeskStay",
                    tagline: "Mémorise et restaure la position des icônes du Bureau et des fenêtres, par combinaison d'écrans.",
                    authors: "Par Starbudweiser & Claude Code (Anthropic).",
                    license: "Licence MIT. © 2026 Starbudweiser.",
                    disclaimer: "Logiciel fourni « en l'état », sans garantie d'aucune sorte.",
                    credit: "Inspiré de Desktop Icon Manager et de Stay, sans lien avec leurs auteurs."),
        "en": Texts(menu: "About DeskStay",
                    tagline: "Remembers and restores the position of desktop icons and windows, for each combination of displays.",
                    authors: "By Starbudweiser & Claude Code (Anthropic).",
                    license: "MIT License. © 2026 Starbudweiser.",
                    disclaimer: "Provided \"as is\", without warranty of any kind.",
                    credit: "Inspired by Desktop Icon Manager and Stay, not affiliated with their authors."),
        "es": Texts(menu: "Acerca de DeskStay",
                    tagline: "Memoriza y restaura la posición de los iconos del Escritorio y de las ventanas, según la combinación de pantallas.",
                    authors: "Por Starbudweiser y Claude Code (Anthropic).",
                    license: "Licencia MIT. © 2026 Starbudweiser.",
                    disclaimer: "Software proporcionado «tal cual», sin garantía de ningún tipo.",
                    credit: "Inspirado en Desktop Icon Manager y Stay, sin relación con sus autores."),
        "it": Texts(menu: "Informazioni su DeskStay",
                    tagline: "Memorizza e ripristina la posizione delle icone della Scrivania e delle finestre, per ogni combinazione di schermi.",
                    authors: "Di Starbudweiser e Claude Code (Anthropic).",
                    license: "Licenza MIT. © 2026 Starbudweiser.",
                    disclaimer: "Software fornito «così com'è», senza garanzie di alcun tipo.",
                    credit: "Ispirato a Desktop Icon Manager e Stay, senza alcun legame con i loro autori."),
    ]

    private static var current: Texts {
        let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        return texts[code] ?? texts["en"]!
    }

    static var menuTitle: String { current.menu }

    static func show() {
        let t = current
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let font = NSFont.systemFont(ofSize: 11)
        let credits = NSMutableAttributedString()
        for (i, line) in [t.tagline, t.authors, t.license, t.disclaimer, t.credit].enumerated() {
            credits.append(NSAttributedString(string: line + (i < 4 ? "\n" : ""),
                                              attributes: [.font: i == 1 ? NSFont.boldSystemFont(ofSize: 11) : font,
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
