import Foundation
import SwiftUI

typealias ViewState<Value> = SwiftUI.State<Value>

enum FilePriority: Int, CaseIterable, Identifiable, Codable {
    case skip = 0, low = 1, normal = 4, high = 7
    var id: Int { rawValue }
    var title: String { switch self { case .skip: L10n.text("Не загружать"); case .low: L10n.text("Низкий"); case .normal: L10n.text("Обычный"); case .high: L10n.text("Высокий") } }
}
struct TorrentFile: Decodable, Identifiable, Sendable, Equatable {
    let index: Int
    let path: String
    let size: Int64
    let done: Int64
    let priority: Int
    let padding: Bool
    let symlink: Bool
    var id: Int { index }
    var selectable: Bool { !padding && !symlink }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct Transfer: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let draft: Bool
    let name: String
    let phase: String
    let hasMetadata: Bool
    let size: Int64
    let wanted: Int64
    let done: Int64
    let downloadRate: Int64
    let uploadRate: Int64
    let downloaded: Int64
    let uploaded: Int64
    let peers: Int
    let seeds: Int
    let ratio: Double
    let destination: String
    let error: String
    let hash: String
    let files: [TorrentFile]
    let trackers: [String]
    var displayName: String { draft && !hasMetadata && name == "Magnet · получение метаданных" ? L10n.text(name) : name }
    var progress: Double { wanted > 0 ? min(1, Double(done) / Double(wanted)) : 0 }
    var paused: Bool { phase == "paused" }
    var complete: Bool { wanted > 0 && done >= wanted }
    var status: String {
        switch phase {
        case "metadata": L10n.text("Получение списка файлов…")
        case "ready": L10n.text("Готово к добавлению")
        case "paused": L10n.text("Приостановлено")
        case "checking": L10n.text("Проверка файлов…")
        case "seeding": L10n.text("Раздаётся")
        case "error": L10n.message(error)
        default: downloadRate > 0 ? L10n.text("Загружается") : L10n.text("Поиск пиров…")
        }
    }
    var eta: String {
        guard downloadRate > 0 && wanted > done else { return "—" }
        let seconds = Int((wanted - done) / downloadRate)
        if seconds < 60 { return L10n.text("< 1 мин") }
        if seconds < 3600 { return L10n.format("%lld мин", Int64(seconds / 60)) }
        return L10n.format("%lld ч %lld мин", Int64(seconds / 3600), Int64(seconds % 3600 / 60))
    }
}
struct EngineResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let id: String?
    let items: [Transfer]?
    let peers: [PeerDetail]?
    let logs: [LogEntry]?
}
struct PeerDetail: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let address: String
    let client: String
    let countryCode: String
    let downloadRate: Int64
    let uploadRate: Int64
    let progress: Double
    let seed: Bool
    var displayClient: String { client.isEmpty ? L10n.text("Не сообщил") : client == "Определяется…" ? L10n.text(client) : client }
}
struct LogEntry: Decodable, Identifiable, Sendable, Equatable {
    let id: UInt64
    let timestamp: Double
    let level: String
    let message: String
    let torrentID: String
    var displayMessage: String { L10n.message(message) }
}
struct EngineFailure: LocalizedError {
    let message: String
    var errorDescription: String? { L10n.message(message) }
}
enum TransferFilter: String, CaseIterable, Identifiable {
    case all, active, downloading, seeding, paused, error
    var id: Self { self }
    var title: String { switch self { case .all: L10n.text("Все"); case .active: L10n.text("Активные"); case .downloading: L10n.text("Скачиваю"); case .seeding: L10n.text("Раздаю"); case .paused: L10n.text("Приостановлены"); case .error: L10n.text("Ошибки") } }
    var symbol: String { switch self { case .all: "tray.full"; case .active: "waveform.path"; case .downloading: "arrow.down.circle"; case .seeding: "arrow.up.circle"; case .paused: "pause.circle"; case .error: "exclamationmark.circle" } }
    func matches(_ t: Transfer) -> Bool {
        switch self {
        case .all: true
        case .active: t.downloadRate > 0 || t.uploadRate > 0 || t.phase == "checking"
        case .downloading: t.phase == "downloading" || t.phase == "metadata" || t.phase == "checking"
        case .seeding: t.phase == "seeding"
        case .paused: t.paused
        case .error: !t.error.isEmpty
        }
    }
}
struct Preferences: Codable, Equatable, Sendable {
    var downloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
    var startImmediately = true
    var appearance = "system"
    var language = "system"
    var filterFont = 17.0
    var confirmRemove = true
    var downLimit = 0
    var upLimit = 0
    var alternate = false
    var altDown = 1024
    var altUp = 128
    var ratioLimit = 0.0
    var connections = 400
    var dht = true
    var lsd = true
    var portMapping = true
    var port = 51413
    var requireEncryption = false
    var preventSleepWhileDownloading = true

    init() {}
    private enum CodingKeys: String, CodingKey {
        case downloadPath, startImmediately, appearance, language, filterFont, confirmRemove
        case downLimit, upLimit, alternate, altDown, altUp, ratioLimit, connections
        case dht, lsd, portMapping, port, requireEncryption, preventSleepWhileDownloading
    }
    // New settings must not reset existing preferences.v1 records when their key is absent.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadPath = try c.decodeIfPresent(String.self, forKey: .downloadPath) ?? downloadPath
        startImmediately = try c.decodeIfPresent(Bool.self, forKey: .startImmediately) ?? startImmediately
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        language = L10n.normalizedSelection(try c.decodeIfPresent(String.self, forKey: .language) ?? language)
        filterFont = try c.decodeIfPresent(Double.self, forKey: .filterFont) ?? filterFont
        confirmRemove = try c.decodeIfPresent(Bool.self, forKey: .confirmRemove) ?? confirmRemove
        downLimit = try c.decodeIfPresent(Int.self, forKey: .downLimit) ?? downLimit
        upLimit = try c.decodeIfPresent(Int.self, forKey: .upLimit) ?? upLimit
        alternate = try c.decodeIfPresent(Bool.self, forKey: .alternate) ?? alternate
        altDown = try c.decodeIfPresent(Int.self, forKey: .altDown) ?? altDown
        altUp = try c.decodeIfPresent(Int.self, forKey: .altUp) ?? altUp
        ratioLimit = try c.decodeIfPresent(Double.self, forKey: .ratioLimit) ?? ratioLimit
        connections = try c.decodeIfPresent(Int.self, forKey: .connections) ?? connections
        dht = try c.decodeIfPresent(Bool.self, forKey: .dht) ?? dht
        lsd = try c.decodeIfPresent(Bool.self, forKey: .lsd) ?? lsd
        portMapping = try c.decodeIfPresent(Bool.self, forKey: .portMapping) ?? portMapping
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? port
        requireEncryption = try c.decodeIfPresent(Bool.self, forKey: .requireEncryption) ?? requireEncryption
        preventSleepWhileDownloading = try c.decodeIfPresent(Bool.self, forKey: .preventSleepWhileDownloading) ?? preventSleepWhileDownloading
    }
}
struct FileNode: Identifiable {
    var id: String
    var name: String
    var indices: [Int]
    var size: Int64
    var children: [FileNode]?
    static func tree(_ files: [TorrentFile]) -> [FileNode] {
        func level(_ entries: [(TorrentFile, [String])], prefix: String) -> [FileNode] {
            let groups = Dictionary(grouping: entries, by: { $0.1.first ?? $0.0.name })
            return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
                let members = groups[key]!
                let folder = members.contains { $0.1.count > 1 }
                let path = prefix + "/" + key
                return FileNode(id: path, name: key, indices: members.map { $0.0.index }, size: members.reduce(0) { $0 + $1.0.size }, children: folder ? level(members.map { ($0.0, Array($0.1.dropFirst())) }, prefix: path) : nil)
            }
        }
        return level(files.filter(\.selectable).map { ($0, $0.path.split(separator: "/").map(String.init)) }, prefix: "")
    }
}
func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file, spellsOutZero: false).locale(L10n.locale)) }
func rate(_ n: Int64) -> String { L10n.format("%@/с", bytes(n)) }
