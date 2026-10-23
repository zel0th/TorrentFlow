import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        TabView {
            general.tabItem { Label("Основные", systemImage: "gearshape") }
            downloads.tabItem { Label("Загрузки", systemImage: "arrow.down.circle") }
            speed.tabItem { Label("Скорость", systemImage: "speedometer") }
            network.tabItem { Label("Сеть", systemImage: "network") }
        }.padding(16).frame(width: 720, height: 520)
            .preferredColorScheme(store.preferences.appearance == "light" ? .light : store.preferences.appearance == "dark" ? .dark : nil)
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelTitle(title: "Основные", subtitle: "Внешний вид и поведение приложения")
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                    GridRow { Text("Оформление"); Picker("Оформление", selection: $store.preferences.appearance) { Text("Системное").tag("system"); Text("Светлое").tag("light"); Text("Тёмное").tag("dark") }.labelsHidden().frame(width: 260) }
                    GridRow { Text("Шрифт фильтров"); Picker("Размер шрифта", selection: $store.preferences.filterFont) { Text("Крупный · 17 пт").tag(17.0); Text("Ещё крупнее · 19 пт").tag(19.0) }.labelsHidden().frame(width: 260) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Подтверждать удаление загрузки из списка", isOn: $store.preferences.confirmRemove)
            Text("Liquid Glass следует системным настройкам прозрачности и контрастности.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            HStack { Text("TorrentFlow 0.2.0"); Spacer(); Text("libtorrent \(TorrentEngine.version)") }.font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }
    private var downloads: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelTitle(title: "Загрузки", subtitle: "Место сохранения и запуск новых задач")
            GroupBox("Папка по умолчанию") {
                HStack { Image(systemName: "folder.fill").foregroundStyle(FlowStyle.accent); Text(store.preferences.downloadPath).lineLimit(2).truncationMode(.middle).help(store.preferences.downloadPath); Spacer(); Button("Выбрать…") { store.chooseFolder(store.preferences.downloadPath) { store.preferences.downloadPath = $0 } } }.padding(12)
            }
            Toggle("Начинать загрузку сразу после подтверждения", isOn: $store.preferences.startImmediately)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Выбор файлов перед каждым добавлением", systemImage: "checklist").font(.headline)
                    Text("Для .torrent и magnet всегда открывается окно с папкой, файлами и приоритетами. В magnet сначала загружаются только метаданные.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Задачи и их прогресс сохраняются автоматически. Удаление из списка сохраняет файлы на диске.").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(18)
    }
    private var speed: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelTitle(title: "Скорость", subtitle: "Лимиты в КиБ/с · 0 — без ограничения")
            GroupBox("Обычный режим") {
                HStack(spacing: 30) { number("Загрузка", value: $store.preferences.downLimit); number("Отдача", value: $store.preferences.upLimit) }.padding(14)
            }
            GroupBox("Тихий режим") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 30) { number("Загрузка", value: $store.preferences.altDown); number("Отдача", value: $store.preferences.altUp) }
                    Toggle("Включить тихий режим", isOn: $store.preferences.alternate)
                }.padding(14)
            }
            HStack {
                Text("Остановить раздачу при рейтинге")
                TextField("0", value: Binding(get: { store.preferences.ratioLimit }, set: { store.preferences.ratioLimit = min(1000, max(0, $0)) }), format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                Text("0 — без ограничения").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(18)
    }
    private var network: some View {
        VStack(alignment: .leading, spacing: 17) {
            PanelTitle(title: "Сеть", subtitle: "Подключения к пирам и входящий порт")
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
                    GridRow { Text("Входящий порт"); TextField("51413", value: bounded($store.preferences.port, 1024...65535), format: .number.grouping(.never)).frame(width: 100).textFieldStyle(.roundedBorder) }
                    GridRow { Text("Максимум соединений"); TextField("400", value: bounded($store.preferences.connections, 20...5000), format: .number.grouping(.never)).frame(width: 100).textFieldStyle(.roundedBorder) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Автоматическая переадресация порта · UPnP / NAT-PMP", isOn: $store.preferences.portMapping)
            HStack(spacing: 35) { Toggle("Поиск пиров через DHT", isOn: $store.preferences.dht); Toggle("Локальные пиры · LSD", isOn: $store.preferences.lsd) }
            Toggle("Требовать шифрование соединений с пирами", isOn: $store.preferences.requireEncryption)
            Text("По умолчанию шифрование предпочтительно. Требование шифрования может уменьшить число доступных пиров. Обмен пирами PEX включён.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(18)
    }
    private func number(_ title: String, value: Binding<Int>) -> some View {
        HStack { Text(title); TextField("0", value: bounded(value, 0...1_000_000), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 100) }
    }
    private func bounded(_ b: Binding<Int>, _ range: ClosedRange<Int>) -> Binding<Int> { Binding(get: { b.wrappedValue }, set: { b.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }) }
}
