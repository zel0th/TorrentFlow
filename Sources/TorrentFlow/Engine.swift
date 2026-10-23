import Foundation
import TorrentBridge

final class TorrentEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zel0th.TorrentFlow.engine", qos: .utility)
    private var handle: TFEngine?
    static let version: String = { let v = String(cString: tf_version()); return v.hasSuffix(".0") ? String(v.dropLast(2)) : v }()
    init(root: URL) {
        let state = root.appendingPathComponent("Resume", isDirectory: true).path
        let drafts = root.appendingPathComponent("Drafts", isDirectory: true).path
        handle = queue.sync { tf_create(state, drafts) }
    }
    func request(_ operation: @escaping @Sendable (TFEngine?) -> UnsafeMutablePointer<CChar>?) async throws -> EngineResponse {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let handle, let string = operation(handle) else {
                    continuation.resume(throwing: EngineFailure(message: "Не удалось запустить движок libtorrent")); return
                }
                let data = Data(String(cString: string).utf8)
                tf_free(string)
                continuation.resume(returning: data)
            }
        }
        let result = try JSONDecoder().decode(EngineResponse.self, from: data)
        guard result.ok else { throw EngineFailure(message: result.error ?? "Ошибка libtorrent") }
        return result
    }
    func snapshot() async throws -> [Transfer] { try await request { tf_snapshot($0) }.items ?? [] }
    func summary(selectedID: String?) async throws -> [Transfer] {
        let id = selectedID ?? ""
        return try await request { h in id.withCString { tf_snapshot_scoped(h, $0) } }.items ?? []
    }
    func details(_ identifier: String?, includePeers: Bool = true, includeLogs: Bool = true) async throws -> EngineResponse {
        let id = identifier ?? ""
        return try await request { h in id.withCString { tf_details_filtered(h, $0, includePeers ? 1 : 0, includeLogs ? 1 : 0) } }
    }
    func clearLogs(_ identifier: String?) async throws {
        let id = identifier ?? ""
        _ = try await request { h in id.withCString { tf_clear_logs(h, $0) } }
    }
    func note(_ message: String, level: String = "info") async {
        _ = try? await request { h in message.withCString { message in level.withCString { tf_note(h, message, $0) } } }
    }
    func stage(_ source: String) async throws -> String {
        let r = try await request { h in source.withCString { tf_stage(h, $0) } }
        guard let id = r.id else { throw EngineFailure(message: "Не получен идентификатор задачи") }; return id
    }
    func commit(_ id: String, path: String, priorities: [Int32], start: Bool) async throws {
        _ = try await request { h in id.withCString { identifier in path.withCString { path in priorities.withUnsafeBufferPointer { tf_commit(h, identifier, path, $0.baseAddress, Int32($0.count), start ? 1 : 0) } } } }
    }
    func command(_ id: String, _ command: String) async throws {
        _ = try await request { h in id.withCString { id in command.withCString { tf_command(h, id, $0) } } }
    }
    func priorities(_ id: String, _ priorities: [Int32]) async throws {
        _ = try await request { h in id.withCString { id in priorities.withUnsafeBufferPointer { tf_priorities(h, id, $0.baseAddress, Int32($0.count)) } } }
    }
    func configure(_ preferences: Preferences) async throws {
        let json = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        _ = try await request { h in json.withCString { tf_configure(h, $0) } }
    }
    func save() async throws { _ = try await request { tf_save($0) } }
    func shutdown() async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            if let handle { tf_destroy(handle); self.handle = nil }; continuation.resume()
        } }
    }
}
