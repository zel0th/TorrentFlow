import Foundation
import Observation

final class LocalizationChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

@MainActor @main struct LocalizationTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ title: String) {
        guard condition() else { fatalError("FAIL: \(title)") }
        checks += 1
        print("PASS \(title)")
    }
    static func dictionary(_ url: URL) throws -> [String: String] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
    }
    static func formats(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[-+#0 ]*\d*(?:\.\d+)?(?:hh|h|ll|l|z|t|j|L)?[@diuoxXfFeEgGaAcCsSp]"#)
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    }
    static func main() throws {
        let path = CommandLine.arguments[1]
        guard let bundle = Bundle(path: path), let resources = bundle.resourceURL else { fatalError("Fixture bundle unavailable") }
        let ru = try dictionary(resources.appendingPathComponent("ru.lproj/Localizable.strings"))
        let en = try dictionary(resources.appendingPathComponent("en.lproj/Localizable.strings"))
        check(!ru.isEmpty && ru.count >= 200, "substantial Russian and English catalogs are bundled")
        check(Set(ru.keys) == Set(en.keys), "both languages cover exactly the same keys")
        check(ru.allSatisfy { !$0.value.isEmpty } && en.allSatisfy { !$0.value.isEmpty }, "all catalog values are present")
        check(ru.allSatisfy { formats($0.value) == formats(en[$0.key]!) }, "every translation preserves printf argument types and order")
        check(ru.allSatisfy { $0.key == $0.value }, "Russian catalog retains original source wording")
        let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("Sources/TorrentFlow")
        let expression = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\(\"((?:\\.|[^\"\\])*)\""#)
        var referenced = Set<String>()
        for url in try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil) where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let ns = source as NSString
            for match in expression.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let key = try JSONDecoder().decode(String.self, from: Data(("\"" + ns.substring(with: match.range(at: 1)) + "\"").utf8))
                referenced.insert(key)
            }
        }
        check(referenced.count > 200 && referenced.isSubset(of: Set(en.keys)), "every explicit application localization key exists in both catalogs")
        check(L10n.resolveLanguage("ru", preferredLanguages: ["en-US"]) == "ru", "explicit Russian overrides the system")
        check(L10n.resolveLanguage("en", preferredLanguages: ["ru-RU"]) == "en", "explicit English overrides the system")
        check(L10n.resolveLanguage("system", preferredLanguages: ["ru-RU", "en-GB"]) == "ru", "automatic mode recognizes regional Russian")
        check(L10n.resolveLanguage("system", preferredLanguages: ["en-GB", "ru-RU"]) == "en", "automatic mode respects system preference order")
        check(L10n.resolveLanguage("system", preferredLanguages: ["fr-FR", "ru_RU", "en-US"]) == "ru", "automatic mode skips unsupported languages")
        check(L10n.resolveLanguage("system", preferredLanguages: ["de-DE"]) == "en", "unsupported system languages fall back to English")
        check(L10n.resolveLanguage("system", preferredLanguages: []) == "en", "empty system preferences fall back to English")
        check(L10n.resolveLanguage("invalid", preferredLanguages: ["ru-RU"]) == "ru", "invalid saved language safely uses automatic mode")
        check(L10n.normalizedSelection("fr") == "system", "unknown preference values normalize safely")

        let originalSystemLanguages = UserDefaults.standard.object(forKey: "AppleLanguages") as? [String]
        L10n.configure("en", preferredLanguages: ["ru-RU"], bundle: bundle)
        check(L10n.languageCode == "en" && L10n.locale.identifier == "en", "configured language and formatting locale agree")
        check(L10n.text("Файлы") == "Files", "explicit English selects the English resource bundle")
        check(L10n.text("<unknown key>") == "<unknown key>", "unknown keys remain unchanged")
        check(L10n.format("Файлов: %lld · выбрано %@", Int64(7), "2 MB") == "Files: 7 · 2 MB selected", "file-count text formats numeric and string arguments")
        check(FilePriority.high.title == "High" && TransferFilter.paused.title == "Paused", "model titles follow the selected language")
        check(rate(2_000_000).hasSuffix("/s"), "speed units use the chosen language")
        let untouchedName = "Мои данные 100% %@.mkv"
        check(L10n.format("Имя файла %@", untouchedName) == "File name " + untouchedName, "file names and percent signs survive formatted labels")
        check(L10n.message("Неверный приоритет файла") == "Invalid file priority", "exact app engine errors translate")
        check(L10n.message("Небезопасный путь файла: " + untouchedName) == "Unsafe file path: " + untouchedName, "diagnostic template preserves the file path verbatim")
        check(L10n.message("Восстановлен локальный кэш DHT: 42 узлов") == "Local DHT cache restored: 42 nodes", "diagnostic prefix and suffix translate together")
        check(L10n.message("server: Небезопасный путь файла: " + untouchedName) == "server: Небезопасный путь файла: " + untouchedName, "unrecognized third-party messages are not rewritten")
        check(L10n.message("Восстановлен локальный кэш DHT: 42 different suffix") == "Восстановлен локальный кэш DHT: 42 different suffix", "diagnostic templates require the complete suffix")
        check(L10n.resourceURL("Help", withExtension: "html")?.path.contains("en.lproj") == true, "Help follows the explicit language")
        let help = try String(contentsOf: L10n.resourceURL("Help", withExtension: "html")!, encoding: .utf8)
        check(help.contains("lang=\"en\"") && help.contains("Quiet Mode"), "English Help contains translated instructions")

        let observation = LocalizationChangeFlag()
        withObservationTracking { _ = L10n.text("Файлы") } onChange: { observation.mark() }
        L10n.configure("ru", bundle: bundle)
        check(observation.value, "language changes notify observing SwiftUI content")
        check(L10n.text("Файлы") == "Файлы" && FilePriority.high.title == "Высокий", "switching language updates existing call sites immediately")
        check(L10n.message("Небезопасный путь файла: " + untouchedName) == "Небезопасный путь файла: " + untouchedName, "Russian diagnostic text and user data remain intact")
        check(rate(2_000_000).hasSuffix("/с"), "Russian speed suffix is restored immediately")
        check(L10n.resourceURL("Help", withExtension: "html")?.path.contains("ru.lproj") == true, "Russian Help is selected after switching")
        L10n.configure("system", preferredLanguages: ["fr", "en-US"], bundle: bundle)
        check(L10n.text("Файлы") == "Files", "returning to automatic mode reevaluates preferred languages")
        check(UserDefaults.standard.object(forKey: "AppleLanguages") as? [String] == originalSystemLanguages, "app language changes do not modify macOS language preferences")

        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"downloadPath":"/tmp/downloads","downLimit":2048,"alternate":true,"preventSleepWhileDownloading":false}"#.utf8))
        check(old.language == "system" && old.downLimit == 2048 && old.alternate && !old.preventSleepWhileDownloading, "old preference records gain automatic language without losing existing values")
        var chosen = old
        chosen.language = "en"
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(chosen))
        check(restored == chosen, "explicit language persists with the complete settings record")
        let invalid = try JSONDecoder().decode(Preferences.self, from: Data(#"{"language":"unsupported","upLimit":99}"#.utf8))
        check(invalid.language == "system" && invalid.upLimit == 99, "unsupported persisted language retains other settings")
        print("ALL \(checks) LOCALIZATION CHECKS PASSED")
    }
}
