import SwiftUI
import AppKit

struct InspectorView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panel.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
    private var header: some View {
        HStack(spacing: 18) {
            Text("Инспектор").font(.system(size: 15, weight: .semibold))
            Picker("Инспектор", selection: $store.inspectorTab) {
                Text("Обзор").tag(0)
                Text("Файлы").tag(1)
                Text("Трекеры").tag(2)
                Text("Пиры").tag(3)
                Text("Логи").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Инспектор")
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
            case 1: InspectorFiles(store: store, transfer: transfer).id(transfer.id)
            case 2: InspectorTrackers(store: store, transfer: transfer).id(transfer.id)
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
            VStack(alignment: .leading, spacing: 16) {
                summary
                HStack(alignment: .top, spacing: 24) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        metric("Выбрано", bytes(transfer.wanted))
                        metric("Загружено", bytes(transfer.done))
                        metric("Отдано", bytes(transfer.uploaded))
                        metric("Рейтинг", String(format: "%.2f", transfer.ratio))
                        metric("Пиры / Сиды", "\(transfer.peers) / \(transfer.seeds)")
                    }.frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
                    Divider()
                    location.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(transfer.name).font(.system(size: 17, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 10)
                Text(transfer.status).font(.callout).foregroundStyle(transfer.error.isEmpty ? Color.secondary : Color.orange).lineLimit(2)
                Text(transfer.progress, format: .percent.precision(.fractionLength(1)))
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit().fixedSize()
            }
            ProgressView(value: transfer.progress).tint(FlowStyle.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
    }
    private var location: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Папка загрузки").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(transfer.destination).font(.callout).textSelection(.enabled).lineLimit(2).help(transfer.destination)
                Spacer(minLength: 0)
                Button("Показать в Finder") { store.reveal(transfer) }.controlSize(.small)
            }
            Text("Инфохеш").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
            Text(transfer.hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).monospacedDigit() }.font(.system(size: 12)).textSelection(.enabled)
    }
}

private struct InspectorFiles: View {
    @ObservedObject var store: AppStore
    let transfer: Transfer
    @ViewState private var pending: Set<Int> = []
    @ViewState private var displayedPriorities: [Int: Int] = [:]
    private var files: [TorrentFile] { transfer.files.filter(\.selectable) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(files.count) файлов · \(bytes(transfer.wanted)) выбрано")
                Spacer()
                Text("Выберите приоритет в строке файла")
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 37)
            Table(files) {
                TableColumn("Файл") { file in Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path) }.width(min: 280, ideal: 560)
                TableColumn("Размер") { file in Text(bytes(file.size)).monospacedDigit() }.width(110)
                TableColumn("Готово") { file in
                    if file.priority > 0 {
                        Text(file.size > 0 ? Double(file.done) / Double(file.size) : 0, format: .percent.precision(.fractionLength(1))).monospacedDigit()
                    } else { Text("—").foregroundStyle(.secondary) }
                }.width(90)
                TableColumn("Приоритет") { file in priorityPicker(file) }.width(175)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
    private func priorityPicker(_ file: TorrentFile) -> some View {
        Picker("Приоритет \(file.name)", selection: Binding(
            get: { displayedPriorities[file.index] ?? file.priority },
            set: { priority in update(file.index, priority: priority) }
        )) {
            ForEach(FilePriority.allCases) { priority in Text(priority.title).tag(priority.rawValue) }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small)
        .accessibilityLabel("Приоритет \(file.name)")
        .disabled(store.busy || pending.contains(file.index))
    }
    private func update(_ index: Int, priority: Int) {
        guard !store.busy, !pending.contains(index) else { return }
        pending.insert(index); displayedPriorities[index] = priority
        let id = transfer.id
        Task {
            _ = await store.setFilePriority(id, index: index, priority: priority)
            displayedPriorities.removeValue(forKey: index)
            pending.remove(index)
        }
    }
}

private struct InspectorTrackers: View {
    @ObservedObject var store: AppStore
    let transfer: Transfer
    @ViewState private var adding = false
    private var trackers: [TrackerRow] { transfer.trackers.map { TrackerRow(id: $0) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Трекеров: \(trackers.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Добавить трекеры…") { adding = true }.controlSize(.small).disabled(store.busy)
            }.font(.system(size: 12)).padding(.horizontal, 18).frame(height: 37)
            Table(trackers) {
                TableColumn("Адрес трекера") { tracker in Text(tracker.id).textSelection(.enabled).help(tracker.id) }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if trackers.isEmpty {
                    ContentUnavailableView("Трекеров нет", systemImage: "network", description: Text("Добавьте адрес трекера или используйте поиск пиров через DHT и PEX."))
                }
            }
        }
        .sheet(isPresented: $adding) { AddTrackersView(store: store, transfer: transfer) }
    }
    private struct TrackerRow: Identifiable { let id: String }
}

private struct AddTrackersView: View {
    @ObservedObject var store: AppStore
    let transfer: Transfer
    @Environment(\.dismiss) private var dismiss
    @ViewState private var text = ""
    @ViewState private var submitting = false
    @ViewState private var submissionError: String?
    private var lines: [(Int, String)] {
        text.components(separatedBy: .newlines).enumerated().compactMap { offset, value in
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : (offset + 1, line)
        }
    }
    private var invalidLine: Int? { lines.first { !validTracker($0.1) }?.0 }
    private var urls: [String] {
        var seen = Set(transfer.trackers)
        return lines.compactMap { _, value in seen.insert(value).inserted ? value : nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelTitle(title: "Добавить трекеры", subtitle: transfer.name)
            Text("Вставьте по одному адресу на строку. Поддерживаются HTTP, HTTPS и UDP.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 170)
                .border(Color(nsColor: .separatorColor))
                .disabled(submitting)
                .accessibilityLabel("Адреса трекеров, по одному на строку")
            validationMessage.frame(height: 32, alignment: .leading)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                Button(submitting ? "Добавление…" : "Добавить") { submit() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(submitting || store.busy || lines.isEmpty || invalidLine != nil || urls.isEmpty)
            }
        }.padding(24).frame(width: 680)
        .interactiveDismissDisabled(submitting)
        .onChange(of: text) { submissionError = nil }
    }
    @ViewBuilder private var validationMessage: some View {
        if let invalidLine {
            Text("Некорректный адрес в строке \(invalidLine). Проверьте протокол, имя сервера и порт.").font(.system(size: 12)).foregroundStyle(.orange)
        } else if let submissionError {
            Text(submissionError).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
        } else if !lines.isEmpty && urls.isEmpty {
            Text("Все указанные трекеры уже есть в списке.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            Text(urls.isEmpty ? "" : "Будет добавлено адресов: \(urls.count)").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func submit() {
        guard !submitting, !store.busy, invalidLine == nil, !urls.isEmpty else { return }
        let values = urls; submitting = true; submissionError = nil
        Task {
            let success = await store.addTrackers(transfer.id, urls: values)
            submitting = false
            if success { dismiss() }
            else { submissionError = store.editorError ?? "Не удалось добавить трекеры. Повторите попытку." }
        }
    }
    private func validTracker(_ value: String) -> Bool {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https", "udp"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.fragment == nil, components.url != nil else { return false }
        if let port = components.port, !(1...65535).contains(port) { return false }
        return scheme != "udp" || components.port != nil
    }
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

