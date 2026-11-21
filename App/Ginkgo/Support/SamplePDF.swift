import CoreText
import PDFKit
import UIKit

/// Typesets a short book chapter into a real, text-searchable PDF (6 × 9 in trim) with Core Text. Used to seed
/// the library for screenshots and simulator checks (`-seedSample YES`).
enum SamplePDF {
    static let pageSize = CGSize(width: 432, height: 648)

    /// Writes the sample to a temporary file named like a real download and returns its URL.
    static func writeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("A Living Fossil.pdf")
        try render().write(to: url)
        return url
    }

    // MARK: - Content

    static let paragraphs: [String] = [
        "Ginkgo biloba is often called a living fossil. Its lineage reaches back more than two hundred million years, and the leaves of trees lining city streets today are nearly indistinguishable from those pressed into Jurassic stone. Few organisms have changed so little for so long, and fewer still have done it while surviving everything the planet has thrown at them.",
        "What makes the ginkgo remarkable is not strength but redundancy. It hedges against catastrophe by doing many modest things well, rather than one thing brilliantly. Its wood resists fungus, its leaves deter insects, and its roots tolerate compacted soil and polluted air. None of these traits is extraordinary on its own; together they amount to a kind of quiet stubbornness.",
        "Several ginkgo trees stood within two kilometres of the hypocentre in Hiroshima in 1945. They were charred, yet within months they had put out new buds. Botanists still argue about why, but the trees joined the hibakujumoku, the survivor trees that residents have tended ever since with something close to reverence.",
        "For centuries, scholars in China, Korea and Japan tucked ginkgo leaves between the pages of their books. The practice was practical before it was poetic: the leaves were believed to repel the silverfish that fed on paper and paste. A reader's library was, in this sense, guarded by the same tree that had outlasted the dinosaurs.",
        "Patience, for a tree, is not passivity. It is a strategy that pays out over spans no single observer can witness, which may be why we so often mistake it for luck.",
        "The tree's reproductive life is just as unhurried. A ginkgo may take twenty years or more before it bears seed, and the sexes grow on separate trees. Female trees drop fleshy seeds in autumn whose outer coat smells, to put it kindly, of rancid butter. City planners learned to plant only males, which is why most street ginkgoes never fruit at all, and why a whole urban population can descend from a handful of cuttings.",
        "Those cuttings travel well. The ginkgo nearly vanished from the wild, surviving in a few mountain valleys in south-western China, and it is human hands that carried it back across the world. Temple gardeners kept it first; merchants, monks and later botanists did the rest. In that sense the tree is as much a cultural artefact as a natural one, a species that has been read, copied and passed along like a manuscript.",
        "Its leaf is the easiest part of that manuscript to recognise. The blade is a fan, split by a shallow notch into two lobes, and its veins do not branch into a net as in most broad-leaved trees. Instead they fork, again and again, running straight out to the rim. Botanists call this dichotomous venation. Readers have seen something else in it: an open book, its spine at the stem and its pages spreading towards the edge.",
        "In autumn the whole crown turns at once. Within a week or two the leaves go from green to a clear butter yellow, and then, often in a single night after the first hard frost, they fall together. Streets in Tokyo and Seoul are briefly paved in gold. The suddenness is part of the tree's character: long patience, followed by one decisive act.",
        "None of this makes the ginkgo a hero. It is simply a tree that found a way of living that kept working while the world around it changed, and kept changing. That may be the most useful thing a reader can take from it. Durable things are rarely brilliant. They are the ones that keep doing the ordinary work, page after page, long after the people who began them have gone.",
    ]

    // MARK: - Typesetting

    private static func serif(_ size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        var d = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif)!
        if italic, let i = d.withSymbolicTraits(.traitItalic) { d = i }
        return UIFont(descriptor: d, size: size)
    }

    private static func body() -> NSAttributedString {
        let ink = UIColor(red: 0.14, green: 0.125, blue: 0.105, alpha: 1)
        let muted = UIColor(red: 0.48, green: 0.45, blue: 0.41, alpha: 1)
        let out = NSMutableAttributedString()

        let kicker = NSMutableParagraphStyle()
        kicker.paragraphSpacing = 6
        out.append(NSAttributedString(string: "CHAPTER TWO\n", attributes: [
            .font: serif(9, weight: .semibold), .foregroundColor: muted, .kern: 1.6, .paragraphStyle: kicker,
        ]))
        let title = NSMutableParagraphStyle()
        title.paragraphSpacing = 22
        out.append(NSAttributedString(string: "A Living Fossil on the Pavement\n", attributes: [
            .font: serif(21, weight: .semibold), .foregroundColor: ink, .paragraphStyle: title,
        ]))

        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.32
        para.firstLineHeadIndent = 16
        para.alignment = .justified
        para.paragraphSpacing = 2
        para.hyphenationFactor = 0  // keep annotated phrases whole so text search finds them
        for (i, text) in paragraphs.enumerated() {
            let p = para.mutableCopy() as! NSMutableParagraphStyle
            if i == 0 { p.firstLineHeadIndent = 0 }
            let s = NSMutableAttributedString(string: text + "\n", attributes: [
                .font: serif(11), .foregroundColor: ink, .paragraphStyle: p,
            ])
            if i == 0 {
                s.addAttribute(.font, value: serif(11, italic: true), range: NSRange(location: 0, length: 13))
            }
            out.append(s)
        }
        return out
    }

    private static func render() -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let textRect = CGRect(x: 54, y: 66, width: pageSize.width - 108, height: pageSize.height - 66 - 70)
        let setter = CTFramesetterCreateWithAttributedString(body())
        let length = CFAttributedStringGetLength(body())
        let muted = UIColor(red: 0.55, green: 0.52, blue: 0.47, alpha: 1)

        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { r in
            var start = 0
            var page = 1
            while start < length {
                r.beginPage()
                let ctx = r.cgContext

                // Running head and folio.
                let head = page == 1 ? "" : (page % 2 == 0 ? "THE PATIENT TREE" : "A LIVING FOSSIL ON THE PAVEMENT")
                let headAttrs: [NSAttributedString.Key: Any] = [.font: serif(7.5, weight: .medium), .foregroundColor: muted, .kern: 1.2]
                let hs = (head as NSString).size(withAttributes: headAttrs)
                (head as NSString).draw(at: CGPoint(x: (pageSize.width - hs.width) / 2, y: 34), withAttributes: headAttrs)
                let folio = "\(page + 22)" as NSString
                let fs = folio.size(withAttributes: headAttrs)
                folio.draw(at: CGPoint(x: (pageSize.width - fs.width) / 2, y: pageSize.height - 44), withAttributes: headAttrs)

                // Core Text draws in a y-up space.
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: 0, y: pageSize.height)
                ctx.scaleBy(x: 1, y: -1)
                let flipped = CGRect(x: textRect.minX, y: pageSize.height - textRect.maxY,
                                     width: textRect.width, height: textRect.height)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0),
                                                     CGPath(rect: flipped, transform: nil), nil)
                CTFrameDraw(frame, ctx)
                ctx.restoreGState()

                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length == 0 { break }
                start += visible.length
                page += 1
            }
        }
    }
}
