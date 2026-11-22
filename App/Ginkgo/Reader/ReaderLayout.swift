import CoreGraphics

/// Splits the reader between the page and an optional side column.
/// The page takes the full width by default: notes sit on it as small tabs and open as floating cards.
/// The side column only appears in wide windows, in review mode or while a long note is expanded.
struct ReaderLayout {
    let size: CGSize
    /// Whether the side column is showing (decided by the caller from `isWide`, the mode and the expanded note).
    var sidebar = false

    /// Judged on the window's shape and width, not device orientation, so Split View and Stage Manager work too.
    static func isWide(_ size: CGSize) -> Bool { size.width > size.height && size.width >= 960 }
    var isWide: Bool { Self.isWide(size) }

    var hasMarginColumn: Bool { sidebar && isWide }
    var marginWidth: CGFloat { hasMarginColumn ? min(380, size.width * 0.3) : 0 }
    var pageWidth: CGFloat { size.width - marginWidth }
    var columnInset: CGFloat { 18 }
    var cardWidth: CGFloat { marginWidth - columnInset * 2 }
    /// Width of a floating card on the page.
    var floatingCardWidth: CGFloat { min(380, size.width - 64) }
    /// Width of the side panel that shows an expanded note in narrow windows.
    var panelWidth: CGFloat { min(400, size.width * 0.86) }
}
