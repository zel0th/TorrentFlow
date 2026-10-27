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
            Text(L10n.text("Инспектор")).font(.system(size: 15, weight: .semibold))
            Picker(L10n.text("Инспектор"), selection: $store.inspectorTab) {
                Text(L10n.text("Обзор")).tag(0)
                Text(L10n.text("Файлы")).tag(1)
                Text(L10n.text("Трекеры")).tag(2)
                Text(L10n.text("Пиры")).tag(3)
                Text(L10n.text("Логи")).tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.text("Инспектор"))
            .frame(width: 510)
            Spacer(minLength: 8)
            if let transfer = store.selected {
                Text(transfer.displayName).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Button { store.inspector = false } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.text("Скрыть инспектор · ⌥⌘I")).accessibilityLabel(L10n.text("Скрыть инспектор"))
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
            ContentUnavailableView(L10n.text("Выберите загрузку"), systemImage: "info.circle", description: Text(L10n.text("Сведения, файлы, трекеры и пиры появятся здесь. Общие события доступны во вкладке «Логи».")))
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
                        metric(L10n.text("Выбрано"), bytes(transfer.wanted))
                        metric(L10n.text("Загружено"), bytes(transfer.done))
                        metric(L10n.text("Отдано"), bytes(transfer.uploaded))
                        metric(L10n.text("Рейтинг"), String(format: "%.2f", transfer.ratio))
                        metric(L10n.text("Пиры / Сиды"), "\(transfer.peers) / \(transfer.seeds)")
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
                Text(transfer.displayName).font(.system(size: 17, weight: .semibold)).lineLimit(2).textSelection(.enabled)
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
            Text(L10n.text("Папка загрузки")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(transfer.destination).font(.callout).textSelection(.enabled).lineLimit(2).help(transfer.destination)
                Spacer(minLength: 0)
                Button(L10n.text("Показать в Finder")) { store.reveal(transfer) }.controlSize(.small)
            }
            Text(L10n.text("Инфохеш")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
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
                Text(L10n.format("Файлов: %lld · выбрано %@", Int64(files.count), bytes(transfer.wanted)))
                Spacer()
                Text(L10n.text("Выберите приоритет в строке файла"))
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 37)
            Table(files) {
                TableColumn(L10n.text("Файл")) { file in Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path) }.width(min: 280, ideal: 560)
                TableColumn(L10n.text("Размер")) { file in Text(bytes(file.size)).monospacedDigit() }.width(110)
                TableColumn(L10n.text("Готово")) { file in
                    FileCompletionCell(done: file.done, size: file.size, included: file.priority > 0)
                }.width(110)
                TableColumn(L10n.text("Приоритет")) { file in priorityPicker(file) }.width(175)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
    private func priorityPicker(_ file: TorrentFile) -> some View {
        Picker(L10n.format("Приоритет %@", file.name), selection: Binding(
            get: { displayedPriorities[file.index] ?? file.priority },
            set: { priority in update(file.index, priority: priority) }
        )) {
            ForEach(FilePriority.allCases) { priority in Text(priority.title).tag(priority.rawValue) }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small)
        .accessibilityLabel(L10n.format("Приоритет %@", file.name))
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
                Text(L10n.format("Трекеров: %lld", Int64(trackers.count))).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Добавить трекеры…")) { adding = true }.controlSize(.small).disabled(store.busy)
            }.font(.system(size: 12)).padding(.horizontal, 18).frame(height: 37)
            Table(trackers) {
                TableColumn(L10n.text("Адрес трекера")) { tracker in Text(tracker.id).textSelection(.enabled).help(tracker.id) }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if trackers.isEmpty {
                    ContentUnavailableView(L10n.text("Трекеров нет"), systemImage: "network", description: Text(L10n.text("Добавьте адрес трекера или используйте поиск пиров через DHT и PEX.")))
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
            PanelTitle(title: L10n.text("Добавить трекеры"), subtitle: transfer.displayName)
            Text(L10n.text("Вставьте по одному адресу на строку. Поддерживаются HTTP, HTTPS и UDP."))
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 170)
                .border(Color(nsColor: .separatorColor))
                .disabled(submitting)
                .accessibilityLabel(L10n.text("Адреса трекеров, по одному на строку"))
            validationMessage.frame(height: 32, alignment: .leading)
            HStack {
                Spacer()
                Button(L10n.text("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                Button(submitting ? L10n.text("Добавление…") : L10n.text("Добавить")) { submit() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(submitting || store.busy || lines.isEmpty || invalidLine != nil || urls.isEmpty)
            }
        }.padding(24).frame(width: 680)
        .interactiveDismissDisabled(submitting)
        .onChange(of: text) { submissionError = nil }
    }
    @ViewBuilder private var validationMessage: some View {
        if let invalidLine {
            Text(L10n.format("Некорректный адрес в строке %lld. Проверьте протокол, имя сервера и порт.", Int64(invalidLine))).font(.system(size: 12)).foregroundStyle(.orange)
        } else if let submissionError {
            Text(submissionError).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
        } else if !lines.isEmpty && urls.isEmpty {
            Text(L10n.text("Все указанные трекеры уже есть в списке.")).font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            Text(urls.isEmpty ? "" : L10n.format("Будет добавлено адресов: %lld", Int64(urls.count))).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func submit() {
        guard !submitting, !store.busy, invalidLine == nil, !urls.isEmpty else { return }
        let values = urls; submitting = true; submissionError = nil
        Task {
            let success = await store.addTrackers(transfer.id, urls: values)
            submitting = false
            if success { dismiss() }
            else { submissionError = store.editorError ?? L10n.text("Не удалось добавить трекеры. Повторите попытку.") }
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
                Text(L10n.format("Подключено пиров: %lld", Int64(peers.count)))
                Spacer()
                Text(L10n.text("Страна определяется по IP."))
                Link("IP Geolocation by DB-IP", destination: URL(string: "https://db-ip.com")!)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 31)
            Table(peers, selection: $selection) {
                TableColumn(L10n.text("Страна")) { peer in
                    Text(PeerCountry.label(peer.countryCode)).lineLimit(1).help(PeerCountry.name(peer.countryCode))
                }.width(min: 120, ideal: 160)
                TableColumn(L10n.text("IP-адрес")) { peer in Text(peer.address).font(.system(size: 12, design: .monospaced)).lineLimit(1).help(peer.address) }.width(min: 170, ideal: 210)
                TableColumn(L10n.text("Клиент")) { peer in
                    HStack(spacing: 6) {
                        if peer.seed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L10n.text("Сид: все части доступны")) }
                        Text(peer.displayClient).lineLimit(1).help(peer.client)
                    }
                }.width(min: 160, ideal: 230)
                TableColumn(L10n.text("Готово")) { peer in Text(peer.progress, format: .percent.precision(.fractionLength(1))).monospacedDigit() }.width(85)
                TableColumn(L10n.text("Загрузка")) { peer in Text(rate(peer.downloadRate)).monospacedDigit() }.width(105)
                TableColumn(L10n.text("Отдача")) { peer in Text(rate(peer.uploadRate)).monospacedDigit() }.width(105)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { identifiers in
                if let id = identifiers.first, let peer = peers.first(where: { $0.id == id }) {
                    Button(L10n.text("Скопировать IP-адрес")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(peer.address, forType: .string) }
                }
            }
            .overlay {
                if peers.isEmpty {
                    ContentUnavailableView(L10n.text("Нет подключённых пиров"), systemImage: "person.2", description: Text(L10n.text("Адреса, страны и клиенты появятся после подключения.")))
                }
            }
        }
    }
}

private enum PeerCountry {
    static func name(_ code: String) -> String {
        if code == "LOCAL" || code == "LAN" { return L10n.text("Локальная сеть") }
        guard !code.isEmpty else { return L10n.text("Не определена") }
        return L10n.locale.localizedString(forRegionCode: code.uppercased()) ?? code
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
                Text(store.selected == nil ? L10n.text("События всех загрузок и приложения") : L10n.text("События выбранной загрузки и приложения")).foregroundStyle(.secondary)
                Spacer()
                Toggle(L10n.text("Только ошибки"), isOn: $errorsOnly).toggleStyle(.checkbox)
                Button(L10n.text("Очистить")) { store.clearLogs(); selection = nil }.controlSize(.small).disabled(store.logs.isEmpty)
            }.font(.system(size: 12)).padding(.horizontal, 18).frame(height: 36)
            Table(entries, selection: $selection) {
                TableColumn(L10n.text("Время")) { entry in
                    Text(Date(timeIntervalSince1970: entry.timestamp), format: .dateTime.hour().minute().second()).monospacedDigit()
                }.width(95)
                TableColumn(L10n.text("Уровень")) { entry in Label(levelTitle(entry.level), systemImage: levelSymbol(entry.level)).foregroundStyle(levelColor(entry.level)) }.width(145)
                TableColumn(L10n.text("Сообщение")) { entry in Text(entry.displayMessage).lineLimit(1).help(entry.displayMessage) }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(errorsOnly ? L10n.text("Ошибок нет") : L10n.text("Сообщений пока нет"), systemImage: errorsOnly ? "checkmark.circle" : "list.bullet.rectangle")
                }
            }
            if let selected {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: levelSymbol(selected.level)).foregroundStyle(levelColor(selected.level))
                    Text(selected.displayMessage).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(3).help(selected.displayMessage)
                    Spacer(minLength: 0)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.displayMessage, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help(L10n.text("Скопировать сообщение")).accessibilityLabel(L10n.text("Скопировать сообщение"))
                }.padding(.horizontal, 18).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3))
            }
        }
    }
    private func levelTitle(_ level: String) -> String { level == "error" ? L10n.text("Ошибка") : level == "warning" ? L10n.text("Предупреждение") : L10n.text("Информация") }
    private func levelSymbol(_ level: String) -> String { level == "error" ? "xmark.octagon.fill" : level == "warning" ? "exclamationmark.triangle.fill" : "info.circle" }
    private func levelColor(_ level: String) -> Color { level == "error" ? .red : level == "warning" ? .orange : .secondary }
}

