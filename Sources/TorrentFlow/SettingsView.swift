import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ViewState private var selectedTab: Int
    init(store: AppStore, initialTab: Int = 0) {
        self.store = store
        _selectedTab = ViewState(initialValue: initialTab)
    }
    var body: some View {
        VStack(spacing: 8) {
            Picker(L10n.text("Настройки"), selection: $selectedTab) {
                Text(L10n.text("Основные")).tag(0)
                Text(L10n.text("Загрузки")).tag(1)
                Text(L10n.text("Скорость")).tag(2)
                Text(L10n.text("Сеть")).tag(3)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 520).padding(.top, 8)
            Group {
                switch selectedTab {
                case 1: downloads
                case 2: speed
                case 3: network
                default: general
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(16).frame(width: 720, height: 520)
            .environment(\.locale, L10n.locale)
            .preferredColorScheme(store.preferences.appearance == "light" ? .light : store.preferences.appearance == "dark" ? .dark : nil)
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelTitle(title: L10n.text("Основные"), subtitle: L10n.text("Внешний вид и поведение приложения"))
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                    GridRow {
                        Text(L10n.text("Язык"))
                        Picker(L10n.text("Язык приложения"), selection: $store.preferences.language) {
                            Text(L10n.text("Автоматически (язык macOS)")).tag("system")
                            Text("Русский").tag("ru")
                            Text("English").tag("en")
                        }.labelsHidden().frame(width: 310)
                    }
                    GridRow { Text(L10n.text("Оформление")); Picker(L10n.text("Оформление"), selection: $store.preferences.appearance) { Text(L10n.text("Системное")).tag("system"); Text(L10n.text("Светлое")).tag("light"); Text(L10n.text("Тёмное")).tag("dark") }.labelsHidden().frame(width: 260) }
                    GridRow { Text(L10n.text("Шрифт фильтров")); Picker(L10n.text("Размер шрифта"), selection: $store.preferences.filterFont) { Text(L10n.text("Крупный · 17 пт")).tag(17.0); Text(L10n.text("Ещё крупнее · 19 пт")).tag(19.0) }.labelsHidden().frame(width: 260) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(L10n.text("Подтверждать удаление загрузки из списка"), isOn: $store.preferences.confirmRemove)
            Text(L10n.text("Liquid Glass следует системным настройкам прозрачности и контрастности.")).font(.callout).foregroundStyle(.secondary)
            Spacer()
            HStack { Text("TorrentFlow \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.2")"); Spacer(); Text("libtorrent \(TorrentEngine.version)") }.font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }
    private var downloads: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle(title: L10n.text("Загрузки"), subtitle: L10n.text("Место сохранения и запуск новых задач"))
            GroupBox(L10n.text("Папка по умолчанию")) {
                HStack { Image(systemName: "folder.fill").foregroundStyle(FlowStyle.accent); Text(store.preferences.downloadPath).lineLimit(2).truncationMode(.middle).help(store.preferences.downloadPath); Spacer(); Button(L10n.text("Выбрать…")) { store.chooseFolder(store.preferences.downloadPath) { store.preferences.downloadPath = $0 } } }.padding(12)
            }
            Toggle(L10n.text("Начинать загрузку сразу после подтверждения"), isOn: $store.preferences.startImmediately)
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L10n.text("Не переводить Mac в сон во время загрузки"), isOn: $store.preferences.preventSleepWhileDownloading)
                Text(L10n.text("Экран может погаснуть. После паузы или завершения загрузок обычный режим сна восстановится."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.text("Выбор файлов перед каждым добавлением"), systemImage: "checklist").font(.headline)
                    Text(L10n.text("Для .torrent и magnet всегда открывается окно с папкой, файлами и приоритетами. В magnet сначала загружаются только метаданные.")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.text("Задачи и их прогресс сохраняются автоматически. Удаление из списка сохраняет файлы на диске.")).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(18)
    }
    private var speed: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelTitle(title: L10n.text("Скорость"), subtitle: L10n.text("Лимиты в КиБ/с · 0 — без ограничения"))
            GroupBox(L10n.text("Обычный режим")) {
                HStack(spacing: 30) { number(L10n.text("Загрузка"), value: $store.preferences.downLimit); number(L10n.text("Отдача"), value: $store.preferences.upLimit) }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(L10n.text("Тихий режим")) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 30) { number(L10n.text("Загрузка"), value: $store.preferences.altDown); number(L10n.text("Отдача"), value: $store.preferences.altUp) }
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(L10n.text("Включить тихий режим"), isOn: $store.preferences.alternate)
                        Text(L10n.text("Использует отдельные лимиты загрузки и отдачи, чтобы оставить больше скорости другим приложениям. Быстро переключается кнопкой с черепахой внизу окна."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(L10n.text("Остановить раздачу при рейтинге"))
                TextField("0", value: Binding(get: { store.preferences.ratioLimit }, set: { store.preferences.ratioLimit = min(1000, max(0, $0)) }), format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                Text(L10n.text("0 — без ограничения")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(18)
    }
    private var network: some View {
        VStack(alignment: .leading, spacing: 17) {
            PanelTitle(title: L10n.text("Сеть"), subtitle: L10n.text("Подключения к пирам и входящий порт"))
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
                    GridRow { Text(L10n.text("Входящий порт")); TextField("51413", value: bounded($store.preferences.port, 1024...65535), format: .number.grouping(.never)).frame(width: 100).textFieldStyle(.roundedBorder) }
                    GridRow { Text(L10n.text("Максимум соединений")); TextField("400", value: bounded($store.preferences.connections, 20...5000), format: .number.grouping(.never)).frame(width: 100).textFieldStyle(.roundedBorder) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(L10n.text("Автоматическая переадресация порта · UPnP / NAT-PMP"), isOn: $store.preferences.portMapping)
            HStack(spacing: 35) { Toggle(L10n.text("Поиск пиров через DHT"), isOn: $store.preferences.dht); Toggle(L10n.text("Локальные пиры · LSD"), isOn: $store.preferences.lsd) }
            Toggle(L10n.text("Требовать шифрование соединений с пирами"), isOn: $store.preferences.requireEncryption)
            Text(L10n.text("По умолчанию шифрование предпочтительно. Требование шифрования может уменьшить число доступных пиров. Обмен пирами PEX включён.")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(18)
    }
    private func number(_ title: String, value: Binding<Int>) -> some View {
        HStack { Text(title); TextField("0", value: bounded(value, 0...1_000_000), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 100) }
    }
    private func bounded(_ b: Binding<Int>, _ range: ClosedRange<Int>) -> Binding<Int> { Binding(get: { b.wrappedValue }, set: { b.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }) }
}
