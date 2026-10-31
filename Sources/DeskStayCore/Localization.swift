import Foundation

/// Texte localisé (français, anglais, espagnol, italien ; anglais si la langue du système n'en fait pas partie).
/// Les textes sont dans Resources/<langue>.lproj/Localizable.strings, copiés dans l'app par build.sh.
/// Formats : `%@` pour un texte, `%ld` pour un entier.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
