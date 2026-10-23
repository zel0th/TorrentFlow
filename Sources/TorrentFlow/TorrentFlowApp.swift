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
        Window("TorrentFlow", id: "main") { MainView(store: store).tint(FlowStyle.accent).task { await store.runPerformanceScenarioIfRequested() } }
            .defaultSize(width: 1250, height: 750)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Открыть торрент…", action: store.openFiles).keyboardShortcut("o")
                    Button("Открыть magnet-ссылку…") { store.showMagnet = true }.keyboardShortcut("l")
                }
                CommandMenu("Загрузки") {
                    Button("Возобновить выбранную") { if let t = store.selected { store.command(t.id, "resume") } }.disabled(store.selected == nil)
                    Button("Приостановить выбранную") { if let t = store.selected { store.command(t.id, "pause") } }.disabled(store.selected == nil)
                    Divider()
                    Button("Возобновить все") { for t in store.downloads { store.command(t.id, "resume") } }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("Приостановить все") { for t in store.downloads { store.command(t.id, "pause") } }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Divider()
                    Button("Показать в Finder") { if let t = store.selected { store.reveal(t) } }.disabled(store.selected == nil)
                    Button("Проверить файлы") { if let t = store.selected { store.command(t.id, "verify") } }.disabled(store.selected == nil)
                    Button("Удалить из списка…") { if let t = store.selected { store.remove(t.id) } }.keyboardShortcut(.delete, modifiers: .command).disabled(store.selected == nil || store.busy)
                    Button("Удалить вместе с файлами…") { if let t = store.selected { store.requestRemoveWithFiles(t.id) } }.disabled(store.selected == nil || store.busy)
                }
                CommandGroup(after: .toolbar) { Button("Показать инспектор") { store.inspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option]) }
                CommandGroup(replacing: .help) { Button("Справка TorrentFlow") { if let url = Bundle.main.url(forResource: "Help", withExtension: "html") { NSWorkspace.shared.open(url) } } }
            }
        Settings { SettingsView(store: store).tint(FlowStyle.accent) }
    }
}
