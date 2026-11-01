import Foundation

/// Nom de l'appli selon la règle Socle « Nom de l'appli » : tout en majuscules sauf une lettre minuscule,
/// colorée partout où le nom est écrit dans l'interface.
public enum Brand {
    public static let name = "DeSKSTAY"

    /// Plages (en UTF-16, pour NSAttributedString) des lettres minuscules de chaque occurrence du nom dans `text`.
    /// Pas dans un mot, un chemin, un identifiant ni une adresse.
    public static func lowercaseRanges(in text: String) -> [NSRange] {
        let marks = name.utf16.enumerated().filter { CharacterSet.lowercaseLetters.contains(Unicode.Scalar($0.element)!) }.map(\.offset)
        let ns = text as NSString
        var ranges: [NSRange] = []
        var from = 0
        while from < ns.length {
            let found = ns.range(of: name, options: [.literal], range: NSRange(location: from, length: ns.length - from))
            if found.location == NSNotFound { break }
            from = found.location + found.length
            if found.location > 0, isWordPart(ns.character(at: found.location - 1), extra: "./@-_") { continue }
            if from < ns.length, isWordPart(ns.character(at: from), extra: "-_") { continue }
            ranges += marks.map { NSRange(location: found.location + $0, length: 1) }
        }
        return ranges
    }

    private static func isWordPart(_ unit: unichar, extra: String) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || extra.unicodeScalars.contains(scalar)
    }
}
