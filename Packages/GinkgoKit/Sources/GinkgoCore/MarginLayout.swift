import CoreGraphics

/// Places margin items (cards, marks) next to their anchors without overlapping.
public enum MarginLayout {
    public struct Item<ID: Hashable & Sendable>: Hashable, Sendable {
        public var id: ID
        /// Where the item would like to start: the top of its anchor, in the column's coordinates.
        public var anchorY: CGFloat
        public var height: CGFloat

        public init(id: ID, anchorY: CGFloat, height: CGFloat) {
            self.id = id
            self.anchorY = anchorY
            self.height = height
        }
    }

    /// Each item starts at its anchor, or just below the previous item if that would overlap.
    /// Returns the top of every item, keyed by id.
    public static func stack<ID>(_ items: [Item<ID>], gap: CGFloat = 10) -> [ID: CGFloat] {
        var tops: [ID: CGFloat] = [:]
        var floor = -CGFloat.infinity
        for item in items.sorted(by: { $0.anchorY < $1.anchorY }) {
            let top = max(item.anchorY, floor)
            tops[item.id] = top
            floor = top + item.height + gap
        }
        return tops
    }
}
