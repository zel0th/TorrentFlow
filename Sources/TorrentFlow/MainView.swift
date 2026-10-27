import SwiftUI
import AppKit

struct MainView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var store: AppStore
    var body: some View {
        let _ = locale
        VStack(spacing: 0) {
            TransferFilterBar(store: store)
            if store.inspector {
                VSplitView {
                    downloadList.frame(minHeight: 220, idealHeight: 380, maxHeight: .infinity)
                    InspectorView(store: store)
                        .frame(minHeight: 210, idealHeight: 280, maxHeight: .infinity)
                }
            } else {
                downloadList.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("TorrentFlow")
        .navigationSubtitle(store.filter.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: store.openFiles) { Label(L10n.text("Открыть торрент"), systemImage: "plus") }.help(L10n.text("Открыть торрент · ⌘O"))
                Button { store.showMagnet = true } label: { Label(L10n.text("Magnet-ссылка"), systemImage: "link") }.help(L10n.text("Открыть magnet-ссылку · ⌘L"))
                Divider()
                Button { if let t = store.selected { store.command(t.id, t.paused ? "resume" : "pause") } } label: { Label(store.selected?.paused == true ? L10n.text("Возобновить") : L10n.text("Пауза"), systemImage: store.selected?.paused == true ? "play.fill" : "pause.fill") }.disabled(store.selected == nil)
                Menu {
                    if let transfer = store.selected {
                        Button(L10n.text("Удалить из списка…"), role: .destructive) { store.remove(transfer.id) }.disabled(store.busy)
                        Button(L10n.text("Удалить вместе с файлами…"), role: .destructive) { store.requestRemoveWithFiles(transfer.id) }.disabled(store.busy)
                    }
                } label: { Label(L10n.text("Удалить"), systemImage: "trash") }.disabled(store.selected == nil || store.busy)
                Button { store.inspector.toggle() } label: { Label(L10n.text("Инспектор"), systemImage: "rectangle.bottomthird.inset.filled") }.help(L10n.text("Показать инспектор · ⌥⌘I"))
            }
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: L10n.text("Имя загрузки"))
        .frame(minWidth: 1060, minHeight: 650)
        .preferredColorScheme(store.preferences.appearance == "light" ? .light : store.preferences.appearance == "dark" ? .dark : nil)
        .sheet(isPresented: $store.showMagnet) { MagnetView(store: store) }
        .sheet(isPresented: Binding(get: { store.draftID != nil }, set: { if !$0 { store.finishDraft(cancel: true) } })) { AddTransferView(store: store).id(store.draftID) }
        .alert(L10n.text("Не удалось выполнить операцию"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L10n.text("Понятно"), role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog(store.removeFiles ? L10n.text("Удалить загрузку вместе с файлами?") : L10n.text("Удалить загрузку из списка?"), isPresented: Binding(get: { store.removeID != nil }, set: { if !$0 { store.removeID = nil } }), titleVisibility: .visible) {
            Button(store.removeFiles ? L10n.text("Переместить файлы в Корзину") : L10n.text("Удалить из списка"), role: .destructive) { store.confirmRemoval() }.disabled(store.busy)
            Button(L10n.text("Отмена"), role: .cancel) { store.removeID = nil }
        } message: { Text(store.removeFiles ? L10n.text("Файлы этой загрузки будут перемещены в Корзину, а задача исчезнет из списка. Файлы можно восстановить из Корзины.") : L10n.text("Загруженные файлы останутся на диске.")) }
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { $0.scheme == "magnet" || $0.pathExtension.lowercased() == "torrent" }
            store.importSources(accepted.map { $0.isFileURL ? $0.path : $0.absoluteString }); return !accepted.isEmpty
        }
        .onOpenURL { url in store.importSources([url.isFileURL ? url.path : url.absoluteString]) }
    }
    private var downloadList: some View {
        Group {
            if store.downloads.isEmpty {
                ContentUnavailableView {
                    Label(L10n.text("Готов к загрузкам"), systemImage: "arrow.down.circle")
                } description: {
                    Text(L10n.text("Откройте .torrent или вставьте magnet-ссылку.\nВыберите папку, файлы и приоритеты перед стартом."))
                } actions: {
                    HStack {
                        Button(L10n.text("Открыть торрент…"), action: store.openFiles).buttonStyle(.glassProminent)
                        Button(L10n.text("Magnet-ссылка…")) { store.showMagnet = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedID) {
                    ForEach(store.visible) { transfer in
                        TransferRow(transfer: transfer).tag(transfer.id)
                            .contextMenu { transferActions(transfer) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if store.visible.isEmpty {
                        ContentUnavailableView(L10n.text("Ничего не найдено"), systemImage: "line.3.horizontal.decrease", description: Text(L10n.text("Измените фильтр или поисковый запрос.")))
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
    @ViewBuilder private func transferActions(_ transfer: Transfer) -> some View {
        Button(transfer.paused ? L10n.text("Возобновить") : L10n.text("Приостановить")) { store.command(transfer.id, transfer.paused ? "resume" : "pause") }
        Button(L10n.text("Показать в Finder")) { store.reveal(transfer) }
        Button(L10n.text("Проверить файлы")) { store.command(transfer.id, "verify") }
        Divider()
        Button(L10n.text("Удалить из списка…"), role: .destructive) { store.remove(transfer.id) }.disabled(store.busy)
        Button(L10n.text("Удалить вместе с файлами…"), role: .destructive) { store.requestRemoveWithFiles(transfer.id) }.disabled(store.busy)
    }
    private var statusBar: some View {
        HStack(spacing: 18) {
            Text(L10n.format("%lld из %lld загрузок", Int64(store.visible.count), Int64(store.downloads.count)))
                .foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Label(rate(store.downloadRate), systemImage: "arrow.down").foregroundStyle(FlowStyle.accent)
            Label(rate(store.uploadRate), systemImage: "arrow.up").foregroundStyle(.green)
            Spacer(minLength: 8)
            Text("libtorrent \(TorrentEngine.version)").foregroundStyle(.secondary)
            Button { store.preferences.alternate.toggle() } label: {
                Label(store.preferences.alternate ? L10n.text("Тихий режим включён") : L10n.text("Тихий режим"), systemImage: "tortoise")
            }
            .buttonStyle(.borderless)
            .tint(store.preferences.alternate ? .orange : .secondary)
            .help(L10n.text("Ограничить скорость до значений тихого режима"))
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(.bar)
    }
}

private struct TransferFilterBar: View {
    @Environment(\.locale) private var locale
    @ObservedObject var store: AppStore
    var body: some View {
        let _ = locale
        HStack(spacing: 6) {
            ForEach(TransferFilter.allCases) { item in
                filterButton(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Фильтры загрузок"))
    }
    private func filterButton(_ item: TransferFilter) -> some View {
        let count = store.downloads.filter { item.matches($0) }.count
        let selected = item == store.filter
        return Button { store.filter = item } label: {
            HStack(spacing: 7) {
                Text(item.title)
                    .font(.system(size: store.preferences.filterFont, weight: selected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
            }
            .padding(.horizontal, 13)
            .frame(height: 37)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: .labelColor))
        .background {
            if selected {
                Capsule().fill(FlowStyle.accent.opacity(0.14))
            }
        }
        .accessibilityLabel(L10n.format("%@, %lld загрузок", item.title, Int64(count)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}
struct TransferRow: View {
    @Environment(\.locale) private var locale
    let transfer: Transfer
    private var color: Color { transfer.phase == "error" ? .orange : transfer.paused ? .secondary : transfer.complete ? .green : FlowStyle.accent }
    var body: some View {
        let _ = locale
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: transfer.complete ? "checkmark.circle.fill" : transfer.paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 32, weight: .light)).symbolRenderingMode(.hierarchical).foregroundStyle(color).frame(width: 38).padding(.top, 6)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(transfer.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 10)
                    Text(transfer.progress, format: .percent.precision(.fractionLength(1))).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: transfer.progress).tint(color)
                HStack(spacing: 6) {
                    Text(L10n.format("%@ из %@", bytes(transfer.done), bytes(transfer.wanted)))
                    Text("·")
                    Text(transfer.status).lineLimit(1)
                    Spacer()
                    if transfer.phase == "downloading" && transfer.downloadRate > 0 { Text(L10n.format("Осталось %@", transfer.eta)) }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Label(rate(transfer.downloadRate), systemImage: "arrow.down").foregroundStyle(color)
                    Label(rate(transfer.uploadRate), systemImage: "arrow.up").foregroundStyle(transfer.uploadRate > 0 ? Color.green : .secondary)
                    Spacer()
                    Text(L10n.format("Пиры: %lld · Сиды: %lld", Int64(transfer.peers), Int64(transfer.seeds)))
                }.font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(.vertical, 13).padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
