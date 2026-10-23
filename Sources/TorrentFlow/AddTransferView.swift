import SwiftUI
import AppKit

struct AddTransferView: View {
    @ObservedObject var store: AppStore
    @ViewState private var path = ""
    @ViewState private var priorities: [Int: Int] = [:]
    @ViewState private var start = true
    @ViewState private var free: Int64?
    @ViewState private var search = ""
    private var draft: Transfer? { store.draft }
    private var files: [TorrentFile] { draft?.files ?? [] }
    private var selectable: [TorrentFile] { files.filter(\.selectable) }
    private var selected: [TorrentFile] { selectable.filter { (priorities[$0.index] ?? 4) > 0 } }
    private var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }
    private var enoughSpace: Bool { free.map { selectedSize <= $0 } ?? true }
    private var tree: [FileNode] { FileNode.tree(search.isEmpty ? selectable : selectable.filter { $0.path.localizedCaseInsensitiveContains(search) }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "arrow.down.document.fill").font(.system(size: 34)).foregroundStyle(FlowStyle.accent)
                PanelTitle(title: "Добавить загрузку", subtitle: draft?.name ?? "Подготовка торрента…")
            }.padding(24).flowChrome()
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill").foregroundStyle(FlowStyle.accent).font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Сохранить в").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(path).lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button("Выбрать…") { store.chooseFolder(path) { path = $0; updateSpace() } }
                }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
                HStack {
                    Text("Содержимое торрента").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    TextField("Найти файл", text: $search).textFieldStyle(.roundedBorder).frame(width: 225)
                }
                HStack(spacing: 12) {
                    Button("Выбрать все") { setAll(4) }.disabled(!hasMetadata)
                    Button("Снять выбор") { setAll(0) }.disabled(!hasMetadata)
                    Menu("Приоритет для всех") { ForEach(FilePriority.allCases) { p in Button(p.title) { setAll(p.rawValue) } } }.disabled(!hasMetadata)
                    Spacer()
                    Text("\(selected.count) из \(selectable.count) файлов").foregroundStyle(.secondary)
                }.controlSize(.regular)
                VStack(spacing: 0) {
                    HStack {
                        Text("Файл"); Spacer()
                        Text("Размер").frame(width: 100, alignment: .trailing)
                        Text("Приоритет").frame(width: 135, alignment: .trailing)
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10).background(.quaternary.opacity(0.35))
                    Divider()
                    if hasMetadata {
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(tree) { node in FileTreeRow(node: node, priorities: $priorities, depth: 0) }
                            }.padding(8)
                        }
                        .overlay { if tree.isEmpty { ContentUnavailableView.search(text: search) } }
                    } else {
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.large)
                            Text("Получаем список файлов magnet-ссылки").font(.headline)
                            Text("После получения метаданных выберите файлы и приоритеты.\nЗагрузка содержимого начнётся после подтверждения.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if let error = draft?.error, !error.isEmpty { Text(error).foregroundStyle(.red) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 12)).clipShape(.rect(cornerRadius: 12))
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("К загрузке: \(bytes(selectedSize))").fontWeight(.medium)
                        Text(free.map { "Свободно: \(bytes($0))" } ?? "Свободное место недоступно")
                            .font(.system(size: 12)).foregroundStyle(enoughSpace ? Color.secondary : .red)
                    }
                    Spacer()
                    Toggle("Начать загрузку сразу", isOn: $start).toggleStyle(.checkbox)
                }
                if !enoughSpace { Text("Недостаточно места. Выберите другую папку или меньше файлов.").foregroundStyle(.red).font(.callout) }
            }.padding(22)
            HStack(spacing: 12) {
                Text("Приоритеты можно изменить и после добавления.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { store.finishDraft(cancel: true) }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Button(start ? "Начать загрузку" : "Добавить на паузе") {
                    let values = files.map { Int32($0.selectable ? (priorities[$0.index] ?? 4) : 0) }
                    Task { _ = await store.commit(path: path, priorities: values, start: start) }
                }.buttonStyle(.glassProminent).tint(FlowStyle.accent).keyboardShortcut(.defaultAction)
                    .disabled(!hasMetadata || selected.isEmpty || path.isEmpty || !enoughSpace || store.busy)
            }.padding(20).flowChrome()
        }.frame(width: 900, height: 680)
        .onAppear { path = store.preferences.downloadPath; start = store.preferences.startImmediately; initialize(); updateSpace() }
        .onChange(of: files.count) { initialize() }
        .interactiveDismissDisabled()
    }
    private var hasMetadata: Bool { draft?.hasMetadata == true }
    private func initialize() { for f in files where priorities[f.index] == nil { priorities[f.index] = f.selectable ? 4 : 0 } }
    private func setAll(_ value: Int) { for f in selectable { priorities[f.index] = value } }
    private func updateSpace() {
        let url = URL(fileURLWithPath: path)
        free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

struct FileTreeRow: View {
    let node: FileNode
    @Binding var priorities: [Int: Int]
    var depth: Int
    @ViewState private var expanded = true
    private var values: [Int] { node.indices.map { priorities[$0] ?? 4 } }
    private var checkboxState: Int { values.allSatisfy { $0 == 0 } ? 0 : values.allSatisfy { $0 > 0 } ? 2 : 1 }
    private var title: String { Set(values).count == 1 ? (FilePriority(rawValue: values.first ?? 4)?.title ?? "Обычный") : "Разные" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if node.children != nil {
                    Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 22) }.buttonStyle(.plain).accessibilityLabel(expanded ? "Свернуть \(node.name)" : "Развернуть \(node.name)")
                } else { Color.clear.frame(width: 14, height: 1) }
                MixedCheckbox(state: checkboxState, label: node.name) { chosen in
                    for index in node.indices { priorities[index] = chosen ? 4 : 0 }
                }.frame(width: 18, height: 22)
                Image(systemName: node.children != nil ? "folder.fill" : "doc").foregroundStyle(node.children != nil ? FlowStyle.accent : Color.secondary).frame(width: 18)
                Text(node.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).help(node.id)
                Spacer(minLength: 4)
                Text(bytes(node.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                Menu {
                    ForEach(FilePriority.allCases) { p in Button(p.title) { for i in node.indices { priorities[i] = p.rawValue } } }
                } label: { Text(title).font(.system(size: 12)).frame(width: 113, alignment: .leading) }
                .frame(width: 135).menuStyle(.borderlessButton)
            }.padding(.leading, CGFloat(depth) * 18).padding(.horizontal, 5).frame(height: 33)
                .background(checkboxState == 0 ? Color.clear : FlowStyle.accent.opacity(0.035), in: .rect(cornerRadius: 5))
            if expanded, let children = node.children {
                ForEach(children) { child in FileTreeRow(node: child, priorities: $priorities, depth: depth + 1) }
            }
        }
    }
}

struct MagnetView: View {
    @ObservedObject var store: AppStore
    @ViewState private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelTitle(title: "Открыть magnet-ссылку", subtitle: "Сначала появится список файлов для выбора.")
            TextField("magnet:?xt=urn:btih:…", text: $value).textFieldStyle(.roundedBorder).font(.system(size: 14)).onSubmit(submit)
            HStack { Spacer(); Button("Отмена") { store.showMagnet = false }.keyboardShortcut(.cancelAction); Button("Продолжить", action: submit).buttonStyle(.glassProminent).disabled(!valid).keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 580)
        .onAppear { if let text = NSPasteboard.general.string(forType: .string), text.hasPrefix("magnet:?") { value = text } }
    }
    private var valid: Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("magnet:?") }
    private func submit() { guard valid else { return }; store.showMagnet = false; let input = value.trimmingCharacters(in: .whitespacesAndNewlines); Task { try? await Task.sleep(for: .milliseconds(250)); store.importSources([input]) } }
}
