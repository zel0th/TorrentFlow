import Foundation

enum TransferSelection {
    /// Keep the user's visible selection, otherwise select the first visible task.
    static func resolve(_ selectedID: String?, visibleIDs: [String]) -> String? {
        if let selectedID, visibleIDs.contains(selectedID) { return selectedID }
        return visibleIDs.first
    }
}
