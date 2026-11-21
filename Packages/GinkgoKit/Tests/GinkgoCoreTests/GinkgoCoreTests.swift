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
