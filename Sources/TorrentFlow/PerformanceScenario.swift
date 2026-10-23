import AppKit
import Foundation

/// Developer-only automation for repeatable measurements of the real application.
/// It is inert unless an explicit, isolated benchmark root is supplied.
@MainActor extension AppStore {
    private static var performanceScenarioStarted = false

    func runPerformanceScenarioIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["TORRENTFLOW_PERF_ROOT"],
              let fixture = environment["TORRENTFLOW_PERF_FIXTURE"],
              let destination = environment["TORRENTFLOW_PERF_DESTINATION"],
              environment["TORRENTFLOW_STATE_ROOT"] != nil,
              !Self.performanceScenarioStarted else { return }
        Self.performanceScenarioStarted = true
        let control = URL(fileURLWithPath: root, isDirectory: true)
        func report(_ phase: String, _ extra: [String: Any] = [:]) {
            var value = extra
            value["phase"] = phase
            value["time"] = Date().timeIntervalSince1970
            value["pid"] = ProcessInfo.processInfo.processIdentifier
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                try? data.write(to: control.appendingPathComponent("app-status.json"), options: .atomic)
            }
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: control.appendingPathComponent(name).path) }
        do {
            // Let the ordinary startup task and system chrome finish before idle sampling.
            try await Task.sleep(for: .seconds(2))
            var isolated = Preferences()
            isolated.dht = false; isolated.lsd = false; isolated.portMapping = false
            isolated.connections = 32
            isolated.port = Int(environment["TORRENTFLOW_PERF_PORT"] ?? "54891") ?? 54891
            isolated.downLimit = 8192; isolated.upLimit = 1024
            try await engine.configure(isolated)
            inspector = true
            report("idle-ready")
            while !exists("begin-transfer") { try await Task.sleep(for: .seconds(1)) }
            let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
            let configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let source = configuration?["magnet"] as? String else {
                throw EngineFailure(message: "Benchmark fixture does not contain a magnet URI")
            }
            let identifier = try await engine.stage(source)
            report("metadata")
            let metadataDeadline = Date().addingTimeInterval(45)
            var staged: Transfer?
            repeat {
                await refresh()
                staged = transfers.first { $0.id == identifier && $0.hasMetadata }
                if staged == nil { try await Task.sleep(for: .milliseconds(100)) }
            } while staged == nil && Date() < metadataDeadline
            guard let staged else { throw EngineFailure(message: "Benchmark metadata timed out") }
            let priorities = staged.files.map { Int32($0.selectable ? 4 : 0) }
            try await engine.commit(identifier, path: destination, priorities: priorities, start: true)
            selectedID = identifier
            inspectorTab = 3
            await refresh()
            report("transferring", ["torrentID": identifier, "wanted": staged.files.filter(\.selectable).reduce(Int64(0)) { $0 + $1.size }])
            let deadline = Date().addingTimeInterval(120)
            var transfer: Transfer?
            repeat {
                try await Task.sleep(for: .milliseconds(500))
                transfer = transfers.first { $0.id == identifier }
                if let transfer, transfer.complete { break }
            } while Date() < deadline
            guard let transfer, transfer.complete else { throw EngineFailure(message: "Benchmark payload transfer timed out") }
            try await engine.command(identifier, "pause")
            inspectorTab = 4
            await refresh()
            report("completed", ["torrentID": identifier, "wanted": transfer.wanted, "done": transfer.done, "downloaded": transfer.downloaded])
            while !exists("finish") { try await Task.sleep(for: .seconds(1)) }
            report("finished")
            NSApplication.shared.terminate(nil)
        } catch {
            report("error", ["error": error.localizedDescription])
            self.error = error.localizedDescription
        }
    }
}
