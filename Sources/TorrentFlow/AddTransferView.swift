import SwiftUI
import AppKit

struct AddTransferView: View {
    @ObservedObject var store: AppStore
    @ViewState private var path = ""
    @ViewState private var priorities: [Int: Int] = [:]
    @ViewState private var start = true
    @ViewState private var free: Int64?
    @ViewState private var search = ""
    @ViewState private var names: [Int: String] = [:]
    @ViewState private var submissionError: String?
    private var draft: Transfer? { store.draft }
    private var files: [TorrentFile] { draft?.files ?? [] }
    private var selectable: [TorrentFile] { files.filter(\.selectable) }
    private var selected: [TorrentFile] { selectable.filter { (priorities[$0.index] ?? 4) > 0 } }
    private var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }
    private var enoughSpace: Bool { free.map { selectedSize <= $0 } ?? true }
    private var tree: [FileNode] {
        FileNode.tree(search.isEmpty ? selectable : selectable.filter {
            $0.path.localizedCaseInsensitiveContains(search) || (names[$0.index]?.localizedCaseInsensitiveContains(search) ?? false)
        })
    }
    private var renameError: String? {
        var destinations: [String: TorrentFile] = [:]
        for file in selectable {
            let name = names[file.index] ?? file.name
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "У файла «\(file.name)» не задано имя."
            }
            if name == "." || name == ".." || name.contains("/") || name.contains(":") || name.unicodeScalars.contains(where: { $0.value == 0 }) {
                return "Имя файла «\(file.name)» не должно быть «.» или «..» и содержать /, : или нулевой символ."
            }
            let parent = (file.path as NSString).deletingLastPathComponent
            let fullPath = parent.isEmpty ? name : parent + "/" + name
            let key = fullPath.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let other = destinations[key] {
                return "Файлы «\(other.name)» и «\(file.name)» получат одинаковый путь. Измените одно из имён."
            }
            destinations[key] = file
        }
        return nil
    }
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
                                ForEach(tree) { node in FileTreeRow(node: node, priorities: $priorities, depth: 0, renameNames: $names) }
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
                if !enoughSpace {
                    Text("Для полной загрузки может не хватить места. Существующие файлы будут проверены; при нехватке места задача остановится с ошибкой.")
                        .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let message = renameError ?? submissionError {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.callout).foregroundStyle(.red).lineLimit(2).help(message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Ошибка: " + message)
                }
            }.padding(22).disabled(store.busy)
            HStack(spacing: 12) {
                Text("Карандаш рядом с файлом позволяет изменить его имя.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { store.finishDraft(cancel: true) }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Button(start ? "Начать загрузку" : "Добавить на паузе") {
                    let values = files.map { Int32($0.selectable ? (priorities[$0.index] ?? 4) : 0) }
                    let chosenNames = names
                    let chosenPath = path
                    let chosenStart = start
                    submissionError = nil
                    Task {
                        let succeeded = await store.commit(path: chosenPath, priorities: values, start: chosenStart, names: chosenNames)
                        if !succeeded {
                            // Keep commit errors in this sheet; a parent alert may be behind the modal.
                            submissionError = store.editorError ?? "Не удалось добавить загрузку. Проверьте папку и имена файлов."
                        }
                    }
                }.buttonStyle(.glassProminent).tint(FlowStyle.accent).keyboardShortcut(.defaultAction)
                    .disabled(!hasMetadata || selected.isEmpty || path.isEmpty || renameError != nil || store.busy)
            }.padding(20).flowChrome()
        }.frame(width: 900, height: 680)
        .onAppear { path = store.preferences.downloadPath; start = store.preferences.startImmediately; initialize(); updateSpace() }
        .onChange(of: files.count) { initialize() }
        .onChange(of: names) { submissionError = nil }
        .onChange(of: path) { submissionError = nil }
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
    var renameNames: Binding<[Int: String]>? = nil
    @ViewState private var editingName = false
    @ViewState private var expanded = true
    private var values: [Int] { node.indices.map { priorities[$0] ?? 4 } }
    private var checkboxState: Int { values.allSatisfy { $0 == 0 } ? 0 : values.allSatisfy { $0 > 0 } ? 2 : 1 }
    private var title: String { Set(values).count == 1 ? (FilePriority(rawValue: values.first ?? 4)?.title ?? "Обычный") : "Разные" }
    private var fileIndex: Int? { node.children == nil && node.indices.count == 1 ? node.indices.first : nil }
    private var displayedName: String { fileIndex.flatMap { renameNames?.wrappedValue[$0] } ?? node.name }
    private var renamed: Bool { displayedName != node.name }
    private var nameBinding: Binding<String> {
        Binding(get: { displayedName }, set: { value in
            guard let index = fileIndex, let renameNames else { return }
            if value == node.name { renameNames.wrappedValue.removeValue(forKey: index) }
            else { renameNames.wrappedValue[index] = value }
        })
    }
    @ViewBuilder private var fileName: some View {
        if renameNames != nil, fileIndex != nil {
            HStack(spacing: 5) {
                if editingName {
                    RenameFileField(name: nameBinding, originalName: node.name) { editingName = false }
                        .frame(minWidth: 55, maxWidth: .infinity).frame(height: 24)
                } else {
                    Text(displayedName.isEmpty ? "Имя не задано" : displayedName)
                        .foregroundStyle(displayedName.isEmpty ? Color.red : Color.primary)
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(renamed ? "Исходное имя: \(node.name)\nНовое имя: \(displayedName)" : node.id)
                        .onTapGesture(count: 2) { editingName = true }
                }
                if renamed {
                    Button { nameBinding.wrappedValue = node.name; editingName = false } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11)).frame(width: 20, height: 24)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Вернуть исходное имя: \(node.name)").accessibilityLabel("Вернуть исходное имя \(node.name)")
                }
                if !editingName {
                    Button { editingName = true } label: {
                        Image(systemName: "pencil").font(.system(size: 11)).frame(width: 20, height: 24)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Переименовать файл").accessibilityLabel("Переименовать \(node.name)")
                }
            }
        } else {
            Text(node.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).help(node.id)
        }
    }
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
                fileName
                Spacer(minLength: 4)
                Text(bytes(node.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                Menu {
                    ForEach(FilePriority.allCases) { p in Button(p.title) { for i in node.indices { priorities[i] = p.rawValue } } }
                } label: { Text(title).font(.system(size: 12)).frame(width: 113, alignment: .leading) }
                .frame(width: 135).menuStyle(.borderlessButton)
            }.padding(.leading, CGFloat(depth) * 18).padding(.horizontal, 5).frame(height: 33)
                .background(checkboxState == 0 ? Color.clear : FlowStyle.accent.opacity(0.035), in: .rect(cornerRadius: 5))
            if expanded, let children = node.children {
                ForEach(children) { child in FileTreeRow(node: child, priorities: $priorities, depth: depth + 1, renameNames: renameNames) }
            }
        }
    }
}

/// A native field editor selects only the basename initially, leaving the extension intact.
/// The extension remains editable when the user explicitly moves the selection into it.
private struct RenameFileField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var name: String
    let originalName: String
    let finished: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: name)
        field.font = .systemFont(ofSize: 13)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Имя файла " + originalName)
        field.toolTip = "Исходное имя: " + originalName
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                let value = field.stringValue as NSString
                let ext = value.pathExtension
                let length = value.length - (ext.isEmpty ? 0 : (ext as NSString).length + 1)
                editor.setSelectedRange(NSRange(location: 0, length: max(0, length)))
            }
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.isEnabled = isEnabled
        context.coordinator.parent = self
        if field.stringValue != name { field.stringValue = name }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameFileField
        let initialName: String
        init(_ parent: RenameFileField) { self.parent = parent; initialName = parent.name }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.name = field.stringValue }
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.finished() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.name = initialName
                parent.finished()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.finished()
                return true
            }
            return false
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
