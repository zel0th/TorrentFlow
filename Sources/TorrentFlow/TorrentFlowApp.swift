import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await AppStore.shared.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@main struct TorrentFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore.shared
    init() {
        if let cert = Bundle.main.path(forResource: "cacert", ofType: "pem") { setenv("SSL_CERT_FILE", cert, 0) }
    }
    var body: some Scene {
        Window("TorrentFlow", id: "main") {
            MainView(store: store).tint(FlowStyle.accent)
                .environment(\.locale, L10n.locale)
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in store.refreshLocalization() }
                .task { await store.runPerformanceScenarioIfRequested() }
        }
            .defaultSize(width: 1250, height: 750)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(L10n.text("Открыть торрент…"), action: store.openFiles).keyboardShortcut("o")
                    Button(L10n.text("Открыть magnet-ссылку…")) { store.showMagnet = true }.keyboardShortcut("l")
                }
                CommandMenu(L10n.text("Загрузки")) {
                    Button(L10n.text("Возобновить выбранную")) { if let t = store.selected { store.command(t.id, "resume") } }.disabled(store.selected == nil)
                    Button(L10n.text("Приостановить выбранную")) { if let t = store.selected { store.command(t.id, "pause") } }.disabled(store.selected == nil)
                    Divider()
                    Button(L10n.text("Возобновить все")) { for t in store.downloads { store.command(t.id, "resume") } }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button(L10n.text("Приостановить все")) { for t in store.downloads { store.command(t.id, "pause") } }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Divider()
                    Button(L10n.text("Показать в Finder")) { if let t = store.selected { store.reveal(t) } }.disabled(store.selected == nil)
                    Button(L10n.text("Проверить файлы")) { if let t = store.selected { store.command(t.id, "verify") } }.disabled(store.selected == nil)
                    Button(L10n.text("Удалить из списка…")) { if let t = store.selected { store.remove(t.id) } }.keyboardShortcut(.delete, modifiers: .command).disabled(store.selected == nil || store.busy)
                    Button(L10n.text("Удалить вместе с файлами…")) { if let t = store.selected { store.requestRemoveWithFiles(t.id) } }.disabled(store.selected == nil || store.busy)
                }
                CommandGroup(after: .toolbar) { Button(L10n.text("Показать инспектор")) { store.inspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option]) }
                CommandGroup(replacing: .help) { Button(L10n.text("Справка TorrentFlow")) { if let url = L10n.resourceURL("Help", withExtension: "html") { NSWorkspace.shared.open(url) } } }
            }
        Settings { SettingsView(store: store).tint(FlowStyle.accent).environment(\.locale, L10n.locale) }
    }
}
