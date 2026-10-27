import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor final class AppStore: ObservableObject {
    static let shared = AppStore()
    @Published var transfers: [Transfer] = []
    @Published var selectedID: String? {
        didSet { if oldValue != selectedID { peers = []; logs = []; Task { await refresh() } } }
    }
    @Published var peers: [PeerDetail] = []
    @Published var logs: [LogEntry] = []
    @Published var inspectorTab = 0 {
        didSet { if oldValue != inspectorTab { Task { await refreshDetails() } } }
    }
    @Published var filter: TransferFilter = .all { didSet { reconcileSelection() } }
    @Published var search = "" { didSet { reconcileSelection() } }
    @Published var inspector = true {
        didSet { if inspector { Task { await refreshDetails() } } else { peers = [] } }
    }
    @Published var showMagnet = false
    @Published var draftID: String?
    @Published var error: String?
    @Published var editorError: String?
    @Published var busy = false
    @Published var removeID: String?
    @Published var removeFiles = false
    @Published var preferences: Preferences {
        didSet {
            if oldValue.language != preferences.language { L10n.configure(preferences.language) }
            updateSleepPrevention()
            if let bytes = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(bytes, forKey: "preferences.v1") }
            var previous = oldValue
            previous.language = preferences.language
            guard previous != preferences else { return }
            configTask?.cancel()
            configTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                do { try await engine.configure(preferences) } catch { self.error = error.localizedDescription }
            }
        }
    }
    let engine: TorrentEngine
    private var pollTask: Task<Void, Never>?
    private var configTask: Task<Void, Never>?
    private var queuedDrafts: [String] = []
    private var advancingDraft = false
    private var importing = false
    private var sources: [String] = []
    private var refreshing = false
    private var refreshRequested = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopping = false
    private let sleepPrevention = SleepPreventionController()
    private init() {
        let restoredPreferences = UserDefaults.standard.data(forKey: "preferences.v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        preferences = restoredPreferences
        L10n.configure(restoredPreferences.language)
        let root: URL
        if let custom = ProcessInfo.processInfo.environment["TORRENTFLOW_STATE_ROOT"] { root = URL(fileURLWithPath: custom) }
        else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("TorrentFlow", isDirectory: true) }
        engine = TorrentEngine(root: root)
        pollTask = Task { [weak self] in
            guard let self else { return }
            do { try await engine.configure(preferences) } catch { self.error = error.localizedDescription }
            var lastSave = Date()
            while !Task.isCancelled {
                await refresh()
                if Date().timeIntervalSince(lastSave) >= 15 {
                    do { try await engine.save() } catch { self.error = error.localizedDescription }
                    lastSave = Date()
                }
                let waitingForMetadata = transfers.contains { $0.draft && !$0.hasMetadata }
                try? await Task.sleep(for: waitingForMetadata ? .milliseconds(250) : .seconds(1))
            }
        }
    }
    func refreshLocalization() {
        if preferences.language == "system" { L10n.configure("system") }
    }
    var downloads: [Transfer] { transfers.filter { !$0.draft } }
    var visible: [Transfer] { downloads.filter { filter.matches($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var selected: Transfer? { downloads.first { $0.id == selectedID } }
    var draft: Transfer? { transfers.first { $0.id == draftID } }
    var downloadRate: Int64 { downloads.reduce(0) { $0 + $1.downloadRate } }
    var uploadRate: Int64 { downloads.reduce(0) { $0 + $1.uploadRate } }
    private func reconcileSelection() {
        let newID = TransferSelection.resolve(selectedID, visibleIDs: visible.map(\.id))
        if newID != selectedID { selectedID = newID }
    }
    private func updateSleepPrevention() {
        guard let change = sleepPrevention.update(preventSleep: !stopping && preferences.preventSleepWhileDownloading, transfers: transfers) else { return }
        let message: String
        let level: String
        switch change {
        case .started: message = "Автоматический сон Mac приостановлен на время загрузки"; level = "info"
        case .stopped: message = "Обычный режим сна Mac восстановлен"; level = "info"
        case .failed(let code): message = "Не удалось обновить блокировку сна Mac (IOKit: \(code))"; level = "warning"
        }
        Task { await engine.note(message, level: level) }
    }
    func refresh() async {
        guard !stopping else { return }
        guard !refreshing else {
            refreshRequested = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        refreshing = true
        defer {
            refreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        repeat {
            refreshRequested = false
            let requestedID = selectedID
            do {
                let updated = try await engine.summary(selectedID: requestedID)
                if updated != transfers { transfers = updated }
                reconcileSelection()
                updateSleepPrevention()
                // A newly selected row needs its full files immediately, not on the next poll.
                if requestedID != selectedID { refreshRequested = true }
                await refreshDetails()
            } catch { self.error = error.localizedDescription }
        } while refreshRequested && !stopping
    }
    func refreshDetails() async {
        guard inspector, inspectorTab == 3 || inspectorTab == 4 else { return }
        let id = selectedID, tab = inspectorTab
        do {
            let details = try await engine.details(id, includePeers: tab == 3, includeLogs: tab == 4)
            guard id == selectedID, tab == inspectorTab, inspector else { return }
            let newPeers = details.peers ?? [], newLogs = details.logs ?? []
            if tab == 3 && newPeers != peers { peers = newPeers }
            if tab == 4 && newLogs != logs { logs = newLogs }
        } catch { self.error = error.localizedDescription }
    }
    func clearLogs() {
        let id = selectedID
        Task {
            do { try await engine.clearLogs(id); await refreshDetails() }
            catch { self.error = error.localizedDescription }
        }
    }
    func openFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]; panel.allowsMultipleSelection = true
        panel.message = L10n.text("Выберите торрент-файлы. Перед загрузкой можно выбрать содержимое и приоритеты.")
        panel.title = L10n.text("Открыть торрент…")
        panel.prompt = L10n.text("Открыть")
        if panel.runModal() == .OK { importSources(panel.urls.map(\.path)) }
    }
    func importSources(_ new: [String]) {
        sources.append(contentsOf: new)
        guard !importing else { return }; importing = true
        Task {
            while !sources.isEmpty {
                let source = sources.removeFirst()
                do {
                    let id = try await engine.stage(source)
                    await refresh()
                    if draftID == nil && !advancingDraft { draftID = id } else { queuedDrafts.append(id) }
                } catch { self.error = error.localizedDescription }
            }
            importing = false
        }
    }
    func finishDraft(cancel: Bool = false) {
        guard !advancingDraft, let id = draftID else { return }
        advancingDraft = true
        Task {
            defer { advancingDraft = false }
            if cancel { do { try await engine.command(id, "cancel") } catch { self.error = error.localizedDescription; return } }
            draftID = nil
            await refresh()
            if !queuedDrafts.isEmpty { let next = queuedDrafts.removeFirst(); try? await Task.sleep(for: .milliseconds(300)); draftID = next }
        }
    }
    func commit(path: String, priorities: [Int32], start: Bool, names: [Int: String] = [:]) async -> Bool {
        guard !busy, let draftID else { return false }; busy = true; defer { busy = false }
        editorError = nil
        do { try await engine.commit(draftID, path: path, priorities: priorities, start: start, names: names); selectedID = draftID; finishDraft(); return true }
        catch { editorError = error.localizedDescription; return false }
    }
    func command(_ id: String, _ command: String) {
        Task { do { try await engine.command(id, command); await refresh() } catch { self.error = error.localizedDescription } }
    }
    func applyPriorities(_ id: String, values: [Int32]) {
        Task { do { try await engine.priorities(id, values); await refresh(); try await engine.save() } catch { self.error = error.localizedDescription } }
    }
    func setFilePriority(_ id: String, index: Int, priority: Int) async -> Bool {
        guard !busy, !stopping else { return false }
        do {
            try await engine.filePriority(id, index: index, priority: priority)
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func addTrackers(_ id: String, urls: [String]) async -> Bool {
        guard !busy, !stopping else { return false }
        editorError = nil
        do {
            try await engine.addTrackers(id, urls: urls)
            await refresh()
            return true
        } catch { editorError = error.localizedDescription; return false }
    }
    func remove(_ id: String) {
        guard !busy else { return }
        removeFiles = false
        if preferences.confirmRemove { removeID = id } else { command(id, "remove") }
    }
    func requestRemoveWithFiles(_ id: String) {
        guard !busy else { return }
        removeFiles = true; removeID = id
    }
    func confirmRemoval() {
        guard !busy, let id = removeID else { return }
        let withFiles = removeFiles
        removeID = nil
        if !withFiles { command(id, "remove"); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                // Obtain a fresh full file list even when the inspector is closed.
                let all = try await engine.snapshot()
                guard let transfer = all.first(where: { $0.id == id && !$0.draft }) else {
                    throw EngineFailure(message: "Загрузка уже удалена")
                }
                let root = URL(fileURLWithPath: transfer.destination).standardizedFileURL.resolvingSymlinksInPath()
                guard root.path != "/", !transfer.destination.isEmpty else { throw EngineFailure(message: "Не удалось определить безопасную папку загрузки") }
                var candidates: [URL] = []
                for file in transfer.files where file.selectable && (file.priority > 0 || file.done > 0) {
                    let url = root.appendingPathComponent(file.path).standardizedFileURL
                    guard url.path.hasPrefix(root.path + "/") else { throw EngineFailure(message: "Небезопасный путь файла: " + file.path) }
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                        throw EngineFailure(message: "Файл находится за пределами папки загрузки или заменён ссылкой: " + file.path)
                    }
                    candidates.append(url)
                }
                // libtorrent names its exact part file using get_best() (v2 truncated to 20 bytes).
                let part = root.appendingPathComponent("." + String(transfer.hash.prefix(40)) + ".parts")
                if FileManager.default.fileExists(atPath: part.path) {
                    let values = try part.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isRegularFile == true && values.isSymbolicLink != true { candidates.append(part) }
                }
                // Another torrent may intentionally reuse the same on-disk file. Never Trash it.
                let selectedPaths = Set(candidates.map { $0.resolvingSymlinksInPath().path })
                for other in all where !other.draft && other.id != id {
                    let otherRoot = URL(fileURLWithPath: other.destination).standardizedFileURL.resolvingSymlinksInPath()
                    for file in other.files where file.selectable && (file.priority > 0 || file.done > 0) {
                        let otherPath = otherRoot.appendingPathComponent(file.path).standardizedFileURL.resolvingSymlinksInPath().path
                        if selectedPaths.contains(otherPath) { throw EngineFailure(message: "Файл используется другой загрузкой: " + file.path + ". Сначала удалите её из списка или выберите удаление без файлов.") }
                    }
                }
                try await engine.command(id, "prepare-remove")
                let paths = candidates
                let failures = await Task.detached(priority: .utility) { () -> [String] in
                    var failed: [String] = []
                    for url in paths {
                        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                        catch { failed.append(url.lastPathComponent + ": " + error.localizedDescription) }
                    }
                    return failed
                }.value
                if failures.isEmpty {
                    try await engine.command(id, "finalize-remove")
                    // Remove only now-empty directories derived from this torrent's file paths.
                    let destination = root
                    await Task.detached(priority: .utility) {
                        var parents: Set<URL> = []
                        for file in paths {
                            var folder=file.deletingLastPathComponent()
                            while folder.path.hasPrefix(destination.path + "/") { parents.insert(folder); folder.deleteLastPathComponent() }
                        }
                        for folder in parents.sorted(by: { $0.path.count > $1.path.count }) {
                            if let contents=try? FileManager.default.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
                                try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                            }
                        }
                    }.value
                    if selectedID == id { selectedID = nil }
                    await engine.note("Загрузка удалена; её файлы перемещены в Корзину: " + transfer.name)
                } else {
                    try await engine.command(id, "restore-remove")
                    let message = "Часть файлов не удалось переместить в Корзину. Загрузка восстановлена на паузе; оставшиеся файлы можно удалить повторно:\n" + failures.prefix(5).joined(separator: "\n")
                    await engine.note(message, level: "error"); self.error = L10n.message(message)
                }
                await refresh()
            } catch {
                try? await engine.command(id, "restore-remove")
                await engine.note("Ошибка удаления файлов: " + error.localizedDescription, level: "error")
                self.error = error.localizedDescription
                await refresh()
            }
        }
    }
    func chooseFolder(_ current: String, completion: (String) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = L10n.text("Папка загрузки")
        panel.prompt = L10n.text("Выбрать")
        panel.directoryURL = URL(fileURLWithPath: current)
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }
    func reveal(_ transfer: Transfer) {
        let urls = transfer.files.filter { $0.priority > 0 && $0.selectable }.map { URL(fileURLWithPath: transfer.destination).appendingPathComponent($0.path) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: transfer.destination)) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    func stop() async {
        stopping = true
        pollTask?.cancel(); configTask?.cancel()
        sleepPrevention.stop()
        await engine.shutdown()
    }
}
