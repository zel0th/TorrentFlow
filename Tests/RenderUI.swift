import AppKit
import SwiftUI
import Foundation
import CryptoKit

/// Renders only the application's own views in hidden test windows. This does
/// not capture the desktop, send UI input, or access the user's running app.
@main struct RenderUI {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(("FAIL UI render: \(error)\n").utf8))
                exit(1)
            }
        }
        application.run()
    }

    @MainActor static func run() async throws {
        guard let root = ProcessInfo.processInfo.environment["TORRENTFLOW_UI_RENDER_ROOT"],
              let stateRoot = ProcessInfo.processInfo.environment["TORRENTFLOW_STATE_ROOT"],
              stateRoot.hasPrefix(root + "/"),
              Bundle.main.bundleIdentifier?.hasPrefix("com.zel0th.TorrentFlow.RenderTests.") == true else {
            throw Failure("An isolated render bundle and state root are required")
        }
        let output = URL(fileURLWithPath: root, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Unique test Bundle ID owns these preferences; the user's app is untouched.
        var preferences = Preferences()
        preferences.downloadPath = output.appendingPathComponent("downloads").path
        preferences.dht = false; preferences.lsd = false; preferences.portMapping = false
        preferences.language = "ru"
        UserDefaults.standard.set(try JSONEncoder().encode(preferences), forKey: "preferences.v1")
        let store = AppStore.shared
        await store.stop()
        let files = [
            TorrentFile(index: 0, path: "Preview/Empty.txt", size: 8_000_000, done: 0, priority: 4, padding: false, symlink: false),
            TorrentFile(index: 1, path: "Preview/Partial — 37.5%.mkv", size: 8_000_000, done: 3_000_000, priority: 7, padding: false, symlink: false),
            TorrentFile(index: 2, path: "Preview/Complete.pdf", size: 8_000_000, done: 8_000_000, priority: 1, padding: false, symlink: false),
            TorrentFile(index: 3, path: "Preview/Skipped.zip", size: 8_000_000, done: 0, priority: 0, padding: false, symlink: false)
        ]
        func fixture(draft: Bool) -> Transfer {
            Transfer(id: draft ? "render-draft" : "render-transfer", draft: draft, name: "TorrentFlow UI Preview", phase: draft ? "ready" : "paused", hasMetadata: true,
                     size: 32_000_000, wanted: 24_000_000, done: 11_000_000, downloadRate: 0, uploadRate: 0,
                     downloaded: 11_000_000, uploaded: 0, peers: 0, seeds: 0, ratio: 0,
                     destination: preferences.downloadPath, error: "", hash: String(repeating: "0", count: 40), files: files, trackers: [])
        }
        let task = fixture(draft: false)
        store.transfers = [task]; store.selectedID = task.id; store.inspectorTab = 1
        var results: [[String: Any]] = []
        for language in ["ru", "en"] {
            store.preferences.language = language
            for tab in 0..<4 {
                let surface = Surface(view: SettingsView(store: store, initialTab: tab), size: NSSize(width: 720, height: 520), dark: false)
                try await surface.settle()
                results.append(try surface.save(name: "settings-\(language)-\(tab)", directory: output, requireNoScroll: true))
                surface.close()
            }
            for dark in [false, true] {
                let surface = Surface(view: InspectorView(store: store).environment(\.locale, L10n.locale), size: NSSize(width: 1120, height: 320), dark: dark)
                try await surface.settle()
                results.append(try surface.save(name: "files-\(language)-\(dark ? "dark" : "light")", directory: output, requireNoScroll: false))
                surface.close()
            }
        }
        // Keep one actual settings view mounted while the language changes.
        // No rootView replacement or .id reset is used between these images.
        store.preferences.language = "ru"
        let live = Surface(view: SettingsView(store: store, initialTab: 2), size: NSSize(width: 720, height: 520), dark: false)
        try await live.settle()
        let first = try live.save(name: "settings-live-ru", directory: output, requireNoScroll: true)
        results.append(first)
        store.preferences.language = "en"
        try await live.settle()
        let second = try live.save(name: "settings-live-en", directory: output, requireNoScroll: true)
        results.append(second)
        store.preferences.language = "ru"
        try await live.settle()
        let third = try live.save(name: "settings-live-ru-again", directory: output, requireNoScroll: true)
        results.append(third)
        guard first["png_sha256"] as? String != second["png_sha256"] as? String else {
            throw Failure("Mounted settings view did not change after switching RU to EN")
        }
        live.close()
        store.transfers = [fixture(draft: true)]; store.selectedID = nil; store.draftID = "render-draft"
        for language in ["ru", "en"] {
            store.preferences.language = language
            let surface = Surface(view: AddTransferView(store: store).environment(\.locale, L10n.locale), size: NSSize(width: 900, height: 680), dark: false)
            try await surface.settle()
            results.append(try surface.save(name: "add-\(language)", directory: output, requireNoScroll: false))
            surface.close()
        }
        let report: [String: Any] = ["bundle_identifier": Bundle.main.bundleIdentifier ?? "", "state_root": stateRoot,
                                    "desktop_captured": false, "input_sent": false, "views": results,
                                    "live_switch_changed_pixels": true,
                                    "live_switch_returned_to_russian_pixels": first["png_sha256"] as? String == third["png_sha256"] as? String]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("ui-render-report.json"))
        FileHandle.standardOutput.write(Data(("PASS \(results.count) UI view renders; mounted RU → EN → RU; settings fit 720 × 520 without vertical scrolling\nREPORT \(output.appendingPathComponent("ui-render-report.json").path)\n").utf8))
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor final class Surface {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let size: NSSize
        init<V: View>(view: V, size: NSSize, dark: Bool) {
            self.size = size
            host = NSHostingView(rootView: AnyView(view.background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light).tint(FlowStyle.accent)))
            host.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -12000, y: -12000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            // Intentionally never ordered on-screen.
        }
        func settle() async throws {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        func save(name: String, directory: URL, requireNoScroll: Bool) throws -> [String: Any] {
            let fitting = host.fittingSize
            guard fitting.width <= size.width + 1, fitting.height <= size.height + 1 else {
                throw Failure("\(name) fitting size \(fitting) exceeds requested \(size)")
            }
            var verticalScrolls: [[String: Any]] = []
            func inspect(_ view: NSView) {
                if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, scroll.hasVerticalScroller,
                   let document = scroll.documentView, document.frame.height > scroll.contentView.bounds.height + 1 {
                    verticalScrolls.append(["document_height": document.frame.height, "viewport_height": scroll.contentView.bounds.height])
                }
                for child in view.subviews { inspect(child) }
            }
            inspect(host)
            if requireNoScroll && !verticalScrolls.isEmpty { throw Failure("\(name) unexpectedly needs vertical scrolling") }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw Failure("Could not allocate bitmap")
            }
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure("PNG encoding failed") }
            let destination = directory.appendingPathComponent(name + ".png")
            try data.write(to: destination)
            return ["name": name, "png": destination.path, "width": size.width, "height": size.height,
                    "fitting_width": fitting.width, "fitting_height": fitting.height,
                    "scrolling_required": verticalScrolls, "png_sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        func close() { window.close() }
    }
}
