import CoreGraphics

/// Splits the reader between the page and the margin column.
/// Wide (landscape, large windows): style A, a margin column with cards beside their lines.
/// Narrow (portrait, Split View): style B, the page takes the full width; notes fold into ticks and open as cards.
struct ReaderLayout {
    let size: CGSize

    /// Judged on the window's shape and width, not device orientation, so Split View and Stage Manager work too.
    var hasMarginColumn: Bool { size.width > size.height && size.width >= 960 }
    var marginWidth: CGFloat { hasMarginColumn ? min(380, size.width * 0.3) : 0 }
    var pageWidth: CGFloat { size.width - marginWidth }
    var columnInset: CGFloat { 18 }
    var cardWidth: CGFloat { marginWidth - columnInset * 2 }
    /// Width of a floating card in style B.
    var floatingCardWidth: CGFloat { min(380, size.width - 64) }
}
