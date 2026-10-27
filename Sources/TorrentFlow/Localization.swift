import Foundation
import Observation

/// App-owned strings use an explicit language bundle, so switching language does
/// not change macOS preferences or discard an open download's editor state.
enum L10n {
    private struct Configuration {
        let code: String
        let root: Bundle
        let strings: Bundle?
    }
    private final class State: Observable, @unchecked Sendable {
        private let lock = NSLock()
        private let observation = ObservationRegistrar()
        private var value: Configuration
        init(_ value: Configuration) { self.value = value }
        var configuration: Configuration {
            observation.access(self, keyPath: \.configuration)
            return lock.withLock { value }
        }
        func update(_ next: Configuration) {
            let changed = lock.withLock { value.code != next.code || value.root.bundleURL != next.root.bundleURL }
            guard changed else { return }
            observation.withMutation(of: self, keyPath: \.configuration) {
                lock.withLock { value = next }
            }
        }
    }
    private static let state = State(configuration("system", preferredLanguages: Locale.preferredLanguages, bundle: .main))

    static func normalizedSelection(_ selection: String) -> String {
        ["system", "ru", "en"].contains(selection) ? selection : "system"
    }
    /// Uses the first supported language in the user's ordered system list.
    /// An unsupported language does not override a later supported preference.
    static func resolveLanguage(_ selection: String, preferredLanguages: [String]) -> String {
        let selected = normalizedSelection(selection)
        if selected != "system" { return selected }
        for language in preferredLanguages {
            let base = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
            if base == "ru" || base == "en" { return base! }
        }
        return "en"
    }
    private static func configuration(_ selection: String, preferredLanguages: [String], bundle: Bundle) -> Configuration {
        let code = resolveLanguage(selection, preferredLanguages: preferredLanguages)
        let strings = bundle.url(forResource: code, withExtension: "lproj").flatMap(Bundle.init(url:))
        return Configuration(code: code, root: bundle, strings: strings)
    }
    static func configure(_ selection: String, preferredLanguages: [String] = Locale.preferredLanguages, bundle: Bundle = .main) {
        state.update(configuration(selection, preferredLanguages: preferredLanguages, bundle: bundle))
    }
    static var languageCode: String { state.configuration.code }
    static var locale: Locale { Locale(identifier: state.configuration.code) }
    static var bundle: Bundle { state.configuration.strings ?? state.configuration.root }
    static func text(_ key: String) -> String {
        let config = state.configuration
        return config.strings?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let config = state.configuration
        let format = config.strings?.localizedString(forKey: key, value: key, table: nil) ?? key
        return String(format: format, locale: Locale(identifier: config.code), arguments: arguments)
    }

    /// Only app-authored, anchored message templates are translated. Captured
    /// paths, torrent names, tracker URLs and third-party error details stay exact.
    static func message(_ raw: String) -> String {
        let config = state.configuration
        guard let strings = config.strings else { return raw }
        let exact = strings.localizedString(forKey: raw, value: raw, table: nil)
        if exact != raw || config.code == "ru" { return exact }
        for template in messageTemplates {
            let parts = template.components(separatedBy: "%@")
            guard parts.count == 2, raw.hasPrefix(parts[0]), raw.hasSuffix(parts[1]),
                  raw.count >= parts[0].count + parts[1].count else { continue }
            let start = raw.index(raw.startIndex, offsetBy: parts[0].count)
            let end = raw.index(raw.endIndex, offsetBy: -parts[1].count)
            var argument = String(raw[start..<end])
            if template == "Превышено время ожидания: %@", timeoutOperations.contains(argument) {
                argument = strings.localizedString(forKey: argument, value: argument, table: nil)
            }
            let translated = strings.localizedString(forKey: template, value: template, table: nil)
            // A missing catalog entry must not expose a format placeholder.
            guard translated != template else { continue }
            return String(format: translated, locale: Locale(identifier: config.code), arguments: [argument])
        }
        return raw
    }
    static func resourceURL(_ name: String, withExtension extensionName: String) -> URL? {
        let config = state.configuration
        return config.strings?.url(forResource: name, withExtension: extensionName)
            ?? config.root.url(forResource: name, withExtension: extensionName)
    }
    private static let timeoutOperations: Set<String> = [
        "переименование файла", "перемещение в папку загрузки",
        "применение приоритетов файлов", "освобождение файлов перед перемещением в Корзину"
    ]
    private static let messageTemplates = [
        "Превышено время ожидания: %@",
        "Восстановлен локальный кэш DHT: %@ узлов",
        "Кэш DHT не прочитан; используется обычный запуск: %@",
        "TorrentFlow: движок libtorrent %@ запущен",
        "Не удалось прочитать сохранённую задачу: %@",
        "Не удалось восстановить задачу: %@",
        "Ошибка восстановления задачи: %@",
        "Не удалось восстановить задачу после удаления: %@",
        "Кэш DHT пока не сохранён: %@",
        "Не удалось проверить путь: %@",
        "Некорректная magnet-ссылка: %@",
        "Метаданные сохранены, но сетевое восстановление черновика не удалось: %@",
        "Не удалось восстановить черновик: %@",
        "Загрузка добавлена, но состояние пока не сохранено: %@",
        "Добавлено трекеров: %@; запрос пиров отправлен",
        "Трекеры добавлены, но сохранение пока не завершено: %@",
        "Изменён приоритет файла №%@",
        "Приоритет изменён, но сохранение пока не завершено: %@",
        "Не удалось обновить блокировку сна Mac (IOKit: %@)",
        "Небезопасный путь файла: %@",
        "Файл находится за пределами папки загрузки или заменён ссылкой: %@",
        "Файл используется другой загрузкой: %@. Сначала удалите её из списка или выберите удаление без файлов.",
        "Загрузка удалена; её файлы перемещены в Корзину: %@",
        "Часть файлов не удалось переместить в Корзину. Загрузка восстановлена на паузе; оставшиеся файлы можно удалить повторно:\n%@",
        "Ошибка удаления файлов: %@"
    ]
}
