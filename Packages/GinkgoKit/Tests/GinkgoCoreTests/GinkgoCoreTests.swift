import CoreGraphics
import Foundation
import Testing
@testable import GinkgoCore

@Suite struct AnchorTests {
    let anchor = Anchor.pdf(PDFAnchor(pageIndex: 3,
                                      rects: [CGRect(x: 72, y: 500, width: 300, height: 14),
                                              CGRect(x: 72, y: 484, width: 120, height: 14)],
                                      range: NSRange(location: 120, length: 48),
                                      quote: "It hedges against every season."))

    @Test func roundTripsThroughData() throws {
        #expect(try Anchor.decoded(from: anchor.encoded()) == anchor)
    }

    @Test func boundsCoverAllLines() {
        guard case .pdf(let a) = anchor else { return }
        #expect(a.bounds == CGRect(x: 72, y: 484, width: 300, height: 30))
    }

    @Test func readingOrderFollowsPageThenText() {
        func at(_ page: Int, _ offset: Int) -> Anchor {
            .pdf(PDFAnchor(pageIndex: page, rects: [], range: NSRange(location: offset, length: 1), quote: ""))
        }
        let sorted = [at(2, 50), at(1, 900), at(2, 10)].sorted { $0.readingOrder < $1.readingOrder }
        #expect(sorted == [at(1, 900), at(2, 10), at(2, 50)])
    }
}

@Suite struct MarginLayoutTests {
    @Test func itemsKeepTheirAnchorWhenThereIsRoom() {
        let tops = MarginLayout.stack([.init(id: "a", anchorY: 0, height: 50), .init(id: "b", anchorY: 100, height: 50)])
        #expect(tops["a"] == 0)
        #expect(tops["b"] == 100)
    }

    @Test func overlappingItemsArePushedDownInAnchorOrder() {
        let tops = MarginLayout.stack([.init(id: "late", anchorY: 30, height: 40),
                                       .init(id: "early", anchorY: 10, height: 80)], gap: 10)
        #expect(tops["early"] == 10)
        #expect(tops["late"] == 100)
    }
}

@Suite struct StrokeClassifierTests {
    // Three text lines in a column from x=60 to x=380.
    let lines = [CGRect(x: 60, y: 100, width: 320, height: 16),
                 CGRect(x: 60, y: 122, width: 320, height: 16),
                 CGRect(x: 60, y: 144, width: 300, height: 16)]
    let column = CGRect(x: 60, y: 100, width: 320, height: 60)

    @Test func flatStrokeUnderALineIsAnUnderline() {
        let pts = stride(from: 90.0, through: 240.0, by: 10).map { CGPoint(x: $0, y: 139 + sin($0) ) }
        guard case .underline(let line, let start, let end) = StrokeClassifier.classify(points: pts, textLines: lines, textColumn: column) else {
            Issue.record("expected underline"); return
        }
        #expect(line == lines[1])
        #expect(start == 90 && end == 240)
    }

    @Test func backAndForthScribbleIsInk() {
        let pts = (0..<20).map { CGPoint(x: $0 % 2 == 0 ? 100 : 200, y: 130 + Double($0) * 0.2) }
        #expect(StrokeClassifier.classify(points: pts, textLines: lines, textColumn: column) == .ink)
    }

    @Test func closedLoopAroundTextIsACircle() {
        let pts = (0...40).map { i -> CGPoint in
            let a = Double(i) / 40 * 2 * .pi
            return CGPoint(x: 200 + cos(a) * 60, y: 130 + sin(a) * 25)
        }
        guard case .circle = StrokeClassifier.classify(points: pts, textLines: lines, textColumn: column) else {
            Issue.record("expected circle"); return
        }
    }

    @Test func flatLoopAroundAPhraseIsACircle() {
        let pts = (0...36).map { i -> CGPoint in
            let a = Double(i) / 36 * 2 * .pi
            return CGPoint(x: 150 + cos(a) * 62, y: 130 + sin(a) * 13)
        }
        guard case .circle = StrokeClassifier.classify(points: pts, textLines: lines, textColumn: column) else {
            Issue.record("expected circle"); return
        }
    }

    @Test func writingBesideTheColumnIsAMarginNote() {
        let pts = [CGPoint(x: 400, y: 120), CGPoint(x: 420, y: 135), CGPoint(x: 410, y: 150)]
        #expect(StrokeClassifier.classify(points: pts, textLines: lines, textColumn: column) == .marginNote(nearLine: lines[1]))
    }
}

@Suite struct StrokeSnappingTests {
    // Three text lines, 20pt tall with 6pt leading, from x 40 to 400.
    let lines = (0..<3).map { CGRect(x: 40, y: 100 + CGFloat($0) * 26, width: 360, height: 20) }

    @Test func highlighterOnOneLineKeepsItsEnds() throws {
        let pts = stride(from: 80.0, through: 200.0, by: 10).map { CGPoint(x: $0, y: 110) }
        let span = try #require(StrokeSnapping.highlight(points: pts, textLines: lines))
        #expect(span.start.x == 81 && span.end.x == 199)
        #expect(span.start.y == lines[0].midY && span.end.y == lines[0].midY)
    }

    @Test func highlighterAcrossLinesRunsFromFirstToLast() throws {
        let pts = [CGPoint(x: 300, y: 110), CGPoint(x: 390, y: 112), CGPoint(x: 60, y: 136), CGPoint(x: 150, y: 138)]
        let span = try #require(StrokeSnapping.highlight(points: pts, textLines: lines))
        #expect(span.start.y == lines[0].midY && span.end.y == lines[1].midY)
        #expect(span.start.x == 301 && span.end.x == 149)
    }

    @Test func highlighterOffTheTextIsNothing() {
        let pts = [CGPoint(x: 420, y: 110), CGPoint(x: 480, y: 112)]
        #expect(StrokeSnapping.highlight(points: pts, textLines: lines) == nil)
    }

    @Test func wavyStrokeUnderALineSnapsToThatLine() throws {
        let pts = stride(from: 100.0, through: 220.0, by: 4).map { CGPoint(x: $0, y: 123 + sin($0 / 4) * 3) }
        let span = try #require(StrokeSnapping.underline(points: pts, textLines: lines))
        #expect(span.start.y == lines[0].midY)
        #expect(span.start.x == 101 && span.end.x == 219)
    }

    @Test func lassoNeedsText() {
        let around = [CGPoint(x: 90, y: 95), CGPoint(x: 200, y: 95), CGPoint(x: 200, y: 125), CGPoint(x: 90, y: 125)]
        #expect(StrokeSnapping.lasso(points: around, textLines: lines) != nil)
        let margin = around.map { CGPoint(x: $0.x + 400, y: $0.y) }
        #expect(StrokeSnapping.lasso(points: margin, textLines: lines) == nil)
    }
}
