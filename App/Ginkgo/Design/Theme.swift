import GinkgoCore
import SwiftUI
import UIKit

/// Paper and ink. Semantic colours adapt around the PDF; the document remains white.
enum Theme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static let paper = adaptive(0xFAF7EF, 0x24232A)
    /// Note cards sit on a white page even in dark mode, so their dark tone is a softer charcoal than panels.
    static let card = adaptive(0xFAF7EF, 0x3A3843)
    static let desk = adaptive(0xEDEAE3, 0x18181D)
    static let margin = adaptive(0xF3F0E8, 0x201F26)
    static let ink = adaptive(0x292735, 0xF1EEE8)
    static let secondaryInk = adaptive(0x66616D, 0xB9B4C2)
    static let accent = adaptive(0x5951A3, 0xBDB5FF)
    static let rule = adaptive(0xD9D4CA, 0x46424E)
    // A dark tint keeps floating glass legible even while it samples a white PDF page.
    static let glassTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.78) : UIColor.clear
    })
    static let swatchInk = Color.black.opacity(0.7)
    static let error = adaptive(0xA33838, 0xFFA6A0)
    static let emptyIconFont = Font.system(.largeTitle, design: .serif).weight(.light)
    static let emptyTitleFont = Font.system(.title2, design: .serif)
    static let calloutFont = Font.callout
    static let largeIconFont = Font.largeTitle
    static let actionFont = Font.footnote.weight(.medium)
    static let doneFont = Font.footnote.weight(.semibold)
    static let panelIconFont = Font.body.weight(.semibold)
    static let metadataFont = Font.caption.weight(.semibold)
    static let checkFont = Font.system(size: Swatch.checkSize, weight: .bold)
    static let panelControlSize: CGFloat = 36
    static let panelShadowX: CGFloat = -4
    static let quoteRuleOpacity = 0.5
    static let success = Color.green
    static let captionFont = Font.caption
    static let footnoteFont = Font.footnote
    static let questionFont = Font.callout.weight(.medium)
    static let menuFont = Font.subheadline.weight(.medium)
    static let quoteFont = Font.system(.callout, design: .serif)
    static let noteFont = Font.system(.subheadline, design: .serif)
    static let titleFont = Font.system(.headline, design: .serif)
    static let labelFont = Font.system(.caption, design: .rounded).weight(.semibold)
    static let cardRadius: CGFloat = 8
    static let coverRadius: CGFloat = 4
    static let cardInset: CGFloat = 16
    static let rhythm: CGFloat = 10
    static let pageInset: CGFloat = 32
    static let coverShadow: CGFloat = 12
    static let floatingShadow: CGFloat = 18
    static let panelRadius: CGFloat = 22
    static let panelWidth: CGFloat = 380
    static let menuInset: CGFloat = 16
    static let menuWidth: CGFloat = 460
    static let controlHeight: CGFloat = 34
    static let swatchSize: CGFloat = 22
    static let hairline: CGFloat = 0.5
    static let markRadius: CGFloat = 2
    static let markReadingOpacity = 0.30
    static let markReviewOpacity = 0.40
    static let markFocusOpacity = 0.52
    enum Space {
        static let tiny: CGFloat = 3
        static let small: CGFloat = 4
        static let compact: CGFloat = 6
        static let regular: CGFloat = 8
        static let medium: CGFloat = 12
        static let generous: CGFloat = 14
        static let section: CGFloat = 20
        static let large: CGFloat = 24
    }
    static let dropRadius: CGFloat = 24
    static let swatchHitWidth: CGFloat = 30
    static let tickWidth: CGFloat = 4
    static let tickHeight: CGFloat = 18
    static let noteRuleWidth: CGFloat = 2
    static let panelShadow: CGFloat = 24
    static let panelShade = Color.black.opacity(0.08)
    static let shadow = Color.black
    enum Mark {
        static let selectionOpacity = 0.28
        static let radius: CGFloat = 2
        static let underlineOpacity = 0.8
        static let underlineWidth: CGFloat = 1.4
    }
    enum Swatch {
        static let checkSize: CGFloat = 10
        static let selectedOpacity = 0.9
        static let idleOpacity = 0.25
        static let selectedBorder: CGFloat = 2
        static let idleBorder: CGFloat = 1
    }
    enum Connector {
        static let focusedOpacity = 0.55
        static let idleOpacity = 0.22
        static let focusedWidth: CGFloat = 1.2
        static let idleWidth: CGFloat = 0.8
        static let tickOpacity = 0.75
    }
    enum Thinking {
        static let interval = 0.25
        static let count = 3
        static let activeOpacity = 0.9
        static let idleOpacity = 0.3
        static let size: CGFloat = 4
    }
    enum Cover {
        static let minimumWidth: CGFloat = 150
        static let maximumWidth: CGFloat = 190
        static let ratio: CGFloat = 0.72
        static let spineWidth: CGFloat = 3
        static let spine = Color.black.opacity(0.08)
        static let shadow = Color.black.opacity(0.16)
        static let shadowX: CGFloat = 2
        static let shadowY: CGFloat = 7
    }
    enum Card {
        static let dotSize: CGFloat = 7
        static let ruleRadius: CGFloat = 1
        static let ruleOpacity = 0.65
        static let focusOpacity = 0.35
        static let borderWidth: CGFloat = 1
        static let marginShadow = Color.black.opacity(0.025)
        static let floatingShadow = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.18) })
        static let marginRadius: CGFloat = 3
        static let marginY: CGFloat = 1
        static let floatingY: CGFloat = 6
    }
    static let panelShadowColor = Color.black.opacity(0.18)
    static let dropLineWidth: CGFloat = 3
    static let dropDash: [CGFloat] = [10, 8]
    static let folioVerticalInset: CGFloat = 7
    static let lineSpacing: CGFloat = 4

    static func highlight(_ color: HighlightColor) -> Color {
        switch color {
        case .yellow: Color(red: 0.97, green: 0.80, blue: 0.29)
        case .green: Color(red: 0.49, green: 0.76, blue: 0.57)
        case .blue: Color(red: 0.43, green: 0.69, blue: 0.91)
        case .pink: Color(red: 0.94, green: 0.53, blue: 0.62)
        case .violet: Color(red: 0.68, green: 0.59, blue: 0.91)
        }
    }
    static func highlightInk(_ color: HighlightColor) -> Color {
        switch color {
        case .yellow: adaptive(0x785513, 0xE8C877)
        case .green: adaptive(0x316444, 0x93D3A5)
        case .blue: adaptive(0x2A5D85, 0x92C9F1)
        case .pink: adaptive(0x963F56, 0xF5A6B8)
        case .violet: adaptive(0x65509A, 0xC9B5FA)
        }
    }
}

/// Only the on-screen preview adapts: stored PencilKit data and PDF exports are untouched.
struct NoteInkAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content.hidden().overlay {
            Rectangle().fill(Theme.ink).mask(content)
        }
    }
}
