import CoreGraphics

/// Splits the reader between the page and an optional side column.
/// The page takes the full width by default: notes sit on it as small tabs and open as floating cards.
/// The side column only appears in wide windows, in review mode or while a note's conversation is open.
struct ReaderLayout {
    let size: CGSize
    /// Whether the side column is showing (decided by the caller from `isWide`, the mode and the expanded note).
    var sidebar = false
    /// The side column holds a note's conversation, which wants a little more room than margin cards.
    var conversation = false
    /// Width the reader wants for the scratch sheet, or 0 when it is closed.
    var scratch: CGFloat = 0

    /// Judged on the window's shape and width, not device orientation, so Split View and Stage Manager work too.
    static func isWide(_ size: CGSize) -> Bool { size.width > size.height && size.width >= 960 }
    var isWide: Bool { Self.isWide(size) }

    /// The scratch sheet sits beside the page in wide windows (taking the side column's place) and floats over it
    /// in narrow ones.
    var scratchBeside: Bool { scratch > 0 && isWide }
    var scratchWidth: CGFloat { min(scratch, isWide ? size.width * 0.5 : size.width - 64) }
    var hasMarginColumn: Bool { sidebar && isWide && !scratchBeside }
    var marginWidth: CGFloat {
        guard hasMarginColumn else { return 0 }
        return conversation ? min(440, size.width * 0.36) : min(380, size.width * 0.3)
    }
    var pageWidth: CGFloat { size.width - marginWidth - (scratchBeside ? scratchWidth : 0) }
    var columnInset: CGFloat { 18 }
    var cardWidth: CGFloat { marginWidth - columnInset * 2 }
    /// Width of a floating card on the page.
    var floatingCardWidth: CGFloat { min(380, size.width - 64) }
    /// Width of the floating conversation panel in narrow windows.
    var panelWidth: CGFloat { min(420, size.width * 0.86) }
}
