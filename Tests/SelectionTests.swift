import Foundation

@main struct SelectionTests {
    static func main() {
        let cases: [(String?, [String], String?)] = [
            (nil, [], nil), (nil, ["a"], "a"), (nil, ["a", "b"], "a"),
            ("b", ["a", "b"], "b"), ("removed", ["a", "b"], "a"),
            ("a", [], nil), ("a", ["b"], "b"), ("b", ["b", "a"], "b")
        ]
        for (selected, visible, expected) in cases {
            precondition(TransferSelection.resolve(selected, visibleIDs: visible) == expected)
        }
        print("PASS: \(cases.count) selection checks (restore, remove, filter, empty list)")
    }
}
