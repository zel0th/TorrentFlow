import SwiftUI
import AppKit

struct MainView: View {
    @ObservedObject var store: AppStore
    var body: some View {
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
                Button(action: store.openFiles) { Label("Открыть торрент", systemImage: "plus") }.help("Открыть торрент · ⌘O")
                Button { store.showMagnet = true } label: { Label("Magnet-ссылка", systemImage: "link") }.help("Открыть magnet-ссылку · ⌘L")
                Divider()
                Button { if let t = store.selected { store.command(t.id, t.paused ? "resume" : "pause") } } label: { Label(store.selected?.paused == true ? "Возобновить" : "Пауза", systemImage: store.selected?.paused == true ? "play.fill" : "pause.fill") }.disabled(store.selected == nil)
                Menu {
                    if let transfer = store.selected {
                        Button("Удалить из списка…", role: .destructive) { store.remove(transfer.id) }.disabled(store.busy)
                        Button("Удалить вместе с файлами…", role: .destructive) { store.requestRemoveWithFiles(transfer.id) }.disabled(store.busy)
                    }
                } label: { Label("Удалить", systemImage: "trash") }.disabled(store.selected == nil || store.busy)
                Button { store.inspector.toggle() } label: { Label("Инспектор", systemImage: "rectangle.bottomthird.inset.filled") }.help("Показать инспектор · ⌥⌘I")
            }
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Имя загрузки")
        .frame(minWidth: 1060, minHeight: 650)
        .preferredColorScheme(store.preferences.appearance == "light" ? .light : store.preferences.appearance == "dark" ? .dark : nil)
        .sheet(isPresented: $store.showMagnet) { MagnetView(store: store) }
        .sheet(isPresented: Binding(get: { store.draftID != nil }, set: { if !$0 { store.finishDraft(cancel: true) } })) { AddTransferView(store: store).id(store.draftID) }
        .alert("Не удалось выполнить операцию", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog(store.removeFiles ? "Удалить загрузку вместе с файлами?" : "Удалить загрузку из списка?", isPresented: Binding(get: { store.removeID != nil }, set: { if !$0 { store.removeID = nil } }), titleVisibility: .visible) {
            Button(store.removeFiles ? "Переместить файлы в Корзину" : "Удалить из списка", role: .destructive) { store.confirmRemoval() }.disabled(store.busy)
            Button("Отмена", role: .cancel) { store.removeID = nil }
        } message: { Text(store.removeFiles ? "Файлы этой загрузки будут перемещены в Корзину, а задача исчезнет из списка. Файлы можно восстановить из Корзины." : "Загруженные файлы останутся на диске.") }
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
                    Label("Готов к загрузкам", systemImage: "arrow.down.circle")
                } description: {
                    Text("Откройте .torrent или вставьте magnet-ссылку.\nВыберите папку, файлы и приоритеты перед стартом.")
                } actions: {
                    HStack {
                        Button("Открыть торрент…", action: store.openFiles).buttonStyle(.glassProminent)
                        Button("Magnet-ссылка…") { store.showMagnet = true }
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
                        ContentUnavailableView("Ничего не найдено", systemImage: "line.3.horizontal.decrease", description: Text("Измените фильтр или поисковый запрос."))
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
    @ViewBuilder private func transferActions(_ transfer: Transfer) -> some View {
        Button(transfer.paused ? "Возобновить" : "Приостановить") { store.command(transfer.id, transfer.paused ? "resume" : "pause") }
        Button("Показать в Finder") { store.reveal(transfer) }
        Button("Проверить файлы") { store.command(transfer.id, "verify") }
        Divider()
        Button("Удалить из списка…", role: .destructive) { store.remove(transfer.id) }.disabled(store.busy)
        Button("Удалить вместе с файлами…", role: .destructive) { store.requestRemoveWithFiles(transfer.id) }.disabled(store.busy)
    }
    private var statusBar: some View {
        HStack(spacing: 18) {
            Text("\(store.visible.count) из \(store.downloads.count) загрузок")
                .foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Label(rate(store.downloadRate), systemImage: "arrow.down").foregroundStyle(FlowStyle.accent)
            Label(rate(store.uploadRate), systemImage: "arrow.up").foregroundStyle(.green)
            Spacer(minLength: 8)
            Text("libtorrent \(TorrentEngine.version)").foregroundStyle(.secondary)
            Button { store.preferences.alternate.toggle() } label: {
                Label(store.preferences.alternate ? "Тихий режим включён" : "Тихий режим", systemImage: "tortoise")
            }
            .buttonStyle(.borderless)
            .tint(store.preferences.alternate ? .orange : .secondary)
            .help("Ограничить скорость до значений тихого режима")
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(.bar)
    }
}

private struct TransferFilterBar: View {
    @ObservedObject var store: AppStore
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(TransferFilter.allCases) { item in
                    filterButton(item)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Фильтры загрузок")
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
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .frame(height: 37)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background {
            if selected {
                Capsule().fill(FlowStyle.accent.opacity(0.14))
            }
        }
        .accessibilityLabel("\(item.title), \(count) загрузок")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}
struct TransferRow: View {
    let transfer: Transfer
    private var color: Color { transfer.phase == "error" ? .orange : transfer.paused ? .secondary : transfer.complete ? .green : FlowStyle.accent }
    var body: some View {
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
                    Text("\(bytes(transfer.done)) из \(bytes(transfer.wanted))")
                    Text("·")
                    Text(transfer.status).lineLimit(1)
                    Spacer()
                    if transfer.phase == "downloading" && transfer.downloadRate > 0 { Text("Осталось \(transfer.eta)") }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Label(rate(transfer.downloadRate), systemImage: "arrow.down").foregroundStyle(color)
                    Label(rate(transfer.uploadRate), systemImage: "arrow.up").foregroundStyle(transfer.uploadRate > 0 ? Color.green : .secondary)
                    Spacer()
                    Text("Пиры: \(transfer.peers) · Сиды: \(transfer.seeds)")
                }.font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(.vertical, 13).padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
