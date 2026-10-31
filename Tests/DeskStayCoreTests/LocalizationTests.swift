import XCTest

/// Les quatre langues ont les mêmes clés, les mêmes champs de format, et toutes les clés utilisées par le code existent.
final class LocalizationTests: XCTestCase {
    static let languages = ["fr", "en", "es", "it"]

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func table(_ language: String, _ name: String = "Localizable") throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/\(name).strings")
        let dict = NSDictionary(contentsOf: url) as? [String: String]
        return try XCTUnwrap(dict, "\(url.path) illisible")
    }

    func testSameKeysInAllLanguages() throws {
        for name in ["Localizable", "InfoPlist"] {
            let fr = Set(try table("fr", name).keys)
            for language in Self.languages.dropFirst() {
                let other = Set(try table(language, name).keys)
                XCTAssertEqual(fr.subtracting(other), [], "\(name) : clés absentes en \(language)")
                XCTAssertEqual(other.subtracting(fr), [], "\(name) : clés en trop en \(language)")
            }
        }
    }

    func testFormatFieldsMatchAcrossLanguages() throws {
        let fields = try NSRegularExpression(pattern: "%ld|%@")
        func list(_ s: String) -> [String] {
            fields.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
        }
        let fr = try table("fr")
        for language in Self.languages.dropFirst() {
            let other = try table(language)
            for (key, text) in fr {
                XCTAssertEqual(list(text), list(other[key] ?? ""), "\(key) : champs de format différents en \(language)")
            }
        }
    }

    func testNoEmptyTextAndEveryUsedKeyExists() throws {
        let fr = try table("fr")
        for language in Self.languages {
            for (key, text) in try table(language) { XCTAssertFalse(text.isEmpty, "\(key) vide en \(language)") }
        }
        let pattern = try NSRegularExpression(pattern: #"\bL\(\s*(?:[a-z]+\s*\?\s*)?\"([A-Za-z.]+)\""#)
        let ternary = try NSRegularExpression(pattern: #"\"([a-z]+\.[A-Za-z]+)\""#)
        var used = Set<String>()
        for folder in ["Sources/DeskStay", "Sources/DeskStayCore"] {
            let dir = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
                let code = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                for line in code.components(separatedBy: "\n") where line.contains("L(") {
                    for m in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) { used.insert(String(line[Range(m.range(at: 1), in: line)!])) }
                    // L(cond ? "a.b" : "c.d") : les deux clés
                    if line.contains("L(") && line.contains(" ? \"") {
                        for m in ternary.matches(in: line, range: NSRange(line.startIndex..., in: line)) { used.insert(String(line[Range(m.range(at: 1), in: line)!])) }
                    }
                }
            }
        }
        for key in used where key.contains(".") && fr[key] == nil {
            XCTFail("clé utilisée mais absente des textes : \(key)")
        }
        XCTAssertGreaterThan(used.count, 40)
    }
}
