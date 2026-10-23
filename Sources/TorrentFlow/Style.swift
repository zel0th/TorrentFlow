import SwiftUI
import AppKit

enum FlowStyle { static let accent = Color(red: 0.04, green: 0.60, blue: 0.73) }
struct FlowChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if reduce || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else {
            content.glassEffect(.regular, in: Rectangle())
        }
    }
}
extension View { func flowChrome() -> some View { modifier(FlowChrome()) } }
struct PanelTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 23, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct MixedCheckbox: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var state: Int // 0 off, 1 mixed, 2 on
    var label: String
    var action: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.click))
        button.allowsMixedState = true; button.setAccessibilityLabel(label)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.isEnabled = isEnabled
        context.coordinator.parent = self
        button.state = state == 0 ? .off : state == 2 ? .on : .mixed
        button.setAccessibilityLabel(label)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: MixedCheckbox
        init(_ p: MixedCheckbox) { parent = p }
        @objc func click() { parent.action(parent.state != 2) }
    }
}
