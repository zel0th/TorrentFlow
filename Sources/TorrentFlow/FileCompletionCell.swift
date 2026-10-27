import SwiftUI

/// A compact progress fill behind the percentage, without a second control in the row.
struct FileCompletionCell: View {
    let done: Int64
    let size: Int64
    let included: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    private var progress: Double { size > 0 ? min(1, max(0, Double(done) / Double(size))) : 0 }
    private var percentage: String { progress.formatted(.percent.precision(.fractionLength(1)).locale(L10n.locale)) }

    var body: some View {
        Text(included ? percentage : "—")
            .font(.system(size: 12, weight: .medium)).monospacedDigit()
            .foregroundStyle(included ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity).frame(height: 22)
            .background {
                if included {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Color.primary.opacity(0.055)
                            FlowStyle.accent.opacity(contrast == .increased ? 0.32 : 0.20)
                                .frame(width: geometry.size.width * progress)
                        }.clipShape(.rect(cornerRadius: 4))
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Готово"))
            .accessibilityValue(included ? percentage : L10n.text("Не загружать"))
    }
}
