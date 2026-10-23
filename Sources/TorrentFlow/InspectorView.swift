import SwiftUI
import AppKit

struct InspectorView: View {
    @ObservedObject var store: AppStore
    @ViewState private var editingFiles = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panel.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $editingFiles) {
            if let transfer = store.selected { EditFilesView(store: store, transfer: transfer) }
        }
    }
    private var header: some View {
        HStack(spacing: 18) {
            Text("Инспектор").font(.system(size: 15, weight: .semibold))
            Picker("Раздел инспектора", selection: $store.inspectorTab) {
                Text("Обзор").tag(0)
                Text("Файлы").tag(1)
                Text("Трекеры").tag(2)
                Text("Пиры").tag(3)
                Text("Логи").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Раздел инспектора")
            .frame(width: 510)
            Spacer(minLength: 8)
            if let transfer = store.selected {
                Text(transfer.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Button { store.inspector = false } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Скрыть инспектор · ⌥⌘I").accessibilityLabel("Скрыть инспектор")
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(.bar)
    }
    @ViewBuilder private var panel: some View {
        if store.inspectorTab == 4 {
            InspectorLogs(store: store)
        } else if let transfer = store.selected {
            switch store.inspectorTab {
            case 1: InspectorFiles(transfer: transfer) { editingFiles = true }
            case 2: InspectorTrackers(transfer: transfer)
            case 3: InspectorPeers(peers: store.peers)
            default: InspectorOverview(store: store, transfer: transfer)
            }
        } else {
            ContentUnavailableView("Выберите загрузку", systemImage: "info.circle", description: Text("Сведения, файлы, трекеры и пиры появятся здесь. Общие события доступны во вкладке «Логи»."))
        }
    }
}

private struct InspectorOverview: View {
    @ObservedObject var store: AppStore
    let transfer: Transfer
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(transfer.name).font(.system(size: 17, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text(transfer.status).font(.callout).foregroundStyle(transfer.error.isEmpty ? Color.secondary : Color.orange)
                    ProgressView(value: transfer.progress).tint(FlowStyle.accent)
                    Text(transfer.progress, format: .percent.precision(.fractionLength(1))).monospacedDigit().foregroundStyle(.secondary)
                }.frame(minWidth: 190, maxWidth: 290, alignment: .leading)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    metric("Выбрано", bytes(transfer.wanted))
                    metric("Загружено", bytes(transfer.done))
                    metric("Отдано", bytes(transfer.uploaded))
                    metric("Рейтинг", String(format: "%.2f", transfer.ratio))
                    metric("Пиры / Сиды", "\(transfer.peers) / \(transfer.seeds)")
                }.frame(minWidth: 235, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Папка загрузки").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(transfer.destination).font(.callout).textSelection(.enabled).lineLimit(2).help(transfer.destination)
                    Button("Показать в Finder") { store.reveal(transfer) }.controlSize(.small)
                    Text("Инфохеш").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
                    Text(transfer.hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).monospacedDigit() }.font(.system(size: 12)).textSelection(.enabled)
    }
}

private struct InspectorFiles: View {
    let transfer: Transfer
    let edit: () -> Void
    private var files: [TorrentFile] { transfer.files.filter(\.selectable) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(files.count) файлов · \(bytes(transfer.wanted)) выбрано").foregroundStyle(.secondary)
                Spacer()
                Button("Выбор и приоритеты…", action: edit).controlSize(.small)
            }.font(.system(size: 12)).padding(.horizontal, 18).frame(height: 37)
            Table(files) {
                TableColumn("Файл") { file in Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path) }.width(min: 280, ideal: 560)
                TableColumn("Размер") { file in Text(bytes(file.size)).monospacedDigit() }.width(110)
                TableColumn("Готово") { file in
                    if file.priority > 0 {
                        Text(file.size > 0 ? Double(file.done) / Double(file.size) : 0, format: .percent.precision(.fractionLength(1))).monospacedDigit()
                    } else { Text("—").foregroundStyle(.secondary) }
                }.width(90)
                TableColumn("Приоритет") { file in Text(FilePriority(rawValue: file.priority)?.title ?? "Обычный").foregroundStyle(file.priority == 0 ? Color.secondary : Color.primary) }.width(145)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

private struct InspectorTrackers: View {
    let transfer: Transfer
    private var trackers: [TrackerRow] { transfer.trackers.map { TrackerRow(id: $0) } }
    var body: some View {
        Table(trackers) {
            TableColumn("Адрес трекера") { tracker in Text(tracker.id).textSelection(.enabled).help(tracker.id) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if trackers.isEmpty {
                ContentUnavailableView("Трекеров нет", systemImage: "network", description: Text("Поиск пиров может выполняться через DHT и PEX."))
            }
        }
    }
    private struct TrackerRow: Identifiable { let id: String }
}

private struct InspectorPeers: View {
    let peers: [PeerDetail]
    @ViewState private var selection: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Подключено пиров: \(peers.count)")
                Spacer()
                Text("Страна определяется по IP.")
                Link("IP Geolocation by DB-IP", destination: URL(string: "https://db-ip.com")!)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 31)
            Table(peers, selection: $selection) {
                TableColumn("Страна") { peer in
                    Text(PeerCountry.label(peer.countryCode)).lineLimit(1).help(PeerCountry.name(peer.countryCode))
                }.width(min: 120, ideal: 160)
                TableColumn("IP-адрес") { peer in Text(peer.address).font(.system(size: 12, design: .monospaced)).lineLimit(1).help(peer.address) }.width(min: 170, ideal: 210)
                TableColumn("Клиент") { peer in
                    HStack(spacing: 6) {
                        if peer.seed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Сид: все части доступны") }
                        Text(peer.client.isEmpty ? "Не сообщил" : peer.client).lineLimit(1).help(peer.client)
                    }
                }.width(min: 160, ideal: 230)
                TableColumn("Готово") { peer in Text(peer.progress, format: .percent.precision(.fractionLength(1))).monospacedDigit() }.width(85)
                TableColumn("Загрузка") { peer in Text(rate(peer.downloadRate)).monospacedDigit() }.width(105)
                TableColumn("Отдача") { peer in Text(rate(peer.uploadRate)).monospacedDigit() }.width(105)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { identifiers in
                if let id = identifiers.first, let peer = peers.first(where: { $0.id == id }) {
                    Button("Скопировать IP-адрес") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(peer.address, forType: .string) }
                }
            }
            .overlay {
                if peers.isEmpty {
                    ContentUnavailableView("Нет подключённых пиров", systemImage: "person.2", description: Text("Адреса, страны и клиенты появятся после подключения."))
                }
            }
        }
    }
}

private enum PeerCountry {
    private static let countries: [String: String] = {
        let locale = Locale(identifier: "ru_RU")
        return Dictionary(uniqueKeysWithValues: Locale.Region.isoRegions.map { region in let code = region.identifier; return (code, locale.localizedString(forRegionCode: code) ?? code) })
    }()
    static func name(_ code: String) -> String {
        if code == "LOCAL" || code == "LAN" { return "Локальная сеть" }
        guard !code.isEmpty else { return "Не определена" }
        return countries[code.uppercased()] ?? code
    }
    static func label(_ code: String) -> String {
        let scalars = code.uppercased().unicodeScalars
        guard scalars.count == 2, scalars.allSatisfy({ (65...90).contains(Int($0.value)) }) else { return name(code) }
        let flag = String(String.UnicodeScalarView(scalars.compactMap { UnicodeScalar(127397 + $0.value) }))
        return "\(flag) \(name(code))"
    }
}

private struct InspectorLogs: View {
    @ObservedObject var store: AppStore
    @ViewState private var errorsOnly = false
    @ViewState private var selection: UInt64?
    private var entries: [LogEntry] { store.logs.reversed().filter { !errorsOnly || $0.level == "error" } }
    private var selected: LogEntry? { store.logs.first { $0.id == selection } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(store.selected == nil ? "События всех загрузок и приложения" : "События выбранной загрузки и приложения").foregroundStyle(.secondary)
                Spacer()
                Toggle("Только ошибки", isOn: $errorsOnly).toggleStyle(.checkbox)
                Button("Очистить") { store.clearLogs(); selection = nil }.controlSize(.small).disabled(store.logs.isEmpty)
            }.font(.system(size: 12)).padding(.horizontal, 18).frame(height: 36)
            Table(entries, selection: $selection) {
                TableColumn("Время") { entry in
                    Text(Date(timeIntervalSince1970: entry.timestamp), format: .dateTime.hour().minute().second()).monospacedDigit()
                }.width(95)
                TableColumn("Уровень") { entry in Label(levelTitle(entry.level), systemImage: levelSymbol(entry.level)).foregroundStyle(levelColor(entry.level)) }.width(145)
                TableColumn("Сообщение") { entry in Text(entry.message).lineLimit(1).help(entry.message) }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(errorsOnly ? "Ошибок нет" : "Сообщений пока нет", systemImage: errorsOnly ? "checkmark.circle" : "list.bullet.rectangle")
                }
            }
            if let selected {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: levelSymbol(selected.level)).foregroundStyle(levelColor(selected.level))
                    Text(selected.message).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(3).help(selected.message)
                    Spacer(minLength: 0)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.message, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Скопировать сообщение").accessibilityLabel("Скопировать сообщение")
                }.padding(.horizontal, 18).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3))
            }
        }
    }
    private func levelTitle(_ level: String) -> String { level == "error" ? "Ошибка" : level == "warning" ? "Предупреждение" : "Информация" }
    private func levelSymbol(_ level: String) -> String { level == "error" ? "xmark.octagon.fill" : level == "warning" ? "exclamationmark.triangle.fill" : "info.circle" }
    private func levelColor(_ level: String) -> Color { level == "error" ? .red : level == "warning" ? .orange : .secondary }
}

struct EditFilesView: View {
    @ObservedObject var store: AppStore
    let transfer: Transfer
    @Environment(\.dismiss) private var dismiss
    @ViewState private var priorities: [Int: Int] = [:]
    var body: some View {
        VStack(spacing: 16) {
            PanelTitle(title: "Файлы и приоритеты", subtitle: transfer.name)
            ScrollView { LazyVStack { ForEach(FileNode.tree(transfer.files)) { node in FileTreeRow(node: node, priorities: $priorities, depth: 0) } } }
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Применить") { store.applyPriorities(transfer.id, values: transfer.files.map { Int32(priorities[$0.index] ?? $0.priority) }); dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!priorities.values.contains { $0 > 0 }) }
        }.padding(24).frame(width: 800, height: 530)
            .onAppear { priorities = Dictionary(uniqueKeysWithValues: transfer.files.map { ($0.index, $0.priority) }) }
    }
}
