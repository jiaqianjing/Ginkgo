import PDFKit
import SwiftUI

/// PDFKit page view. Reports where each note's anchor lines are on screen after every scroll or zoom, so the
/// SwiftUI layers above it (marks on the page, margin notes, connectors) stay glued to the text.
struct PDFReaderView: UIViewRepresentable {
    let model: ReaderModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> PDFView {
        let view = ReaderPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = UIColor(Palette.desk)
        view.pageBreakMargins = UIEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        view.document = model.document
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.refit() }
        context.coordinator.attach(view)
        model.pdfView = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== model.document {
            view.document = model.document
            context.coordinator.refit()
        }
        // Touch the notes so SwiftUI re-runs this when they change, then recompute geometry.
        _ = model.notes.count
        DispatchQueue.main.async { context.coordinator.recompute() }
    }

    final class Coordinator: NSObject {
        let model: ReaderModel
        weak var view: PDFView?
        private var observations: [NSKeyValueObservation] = []
        private var lastWidth: CGFloat = 0

        init(model: ReaderModel) { self.model = model }

        func attach(_ view: PDFView) {
            self.view = view
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(changed), name: .PDFViewScaleChanged, object: view)
            nc.addObserver(self, selector: #selector(changed), name: .PDFViewPageChanged, object: view)
            nc.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
            DispatchQueue.main.async { self.observeScroll() }

            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
        }

        private func observeScroll() {
            guard let view, let scroll = view.firstSubview(of: UIScrollView.self) else { return }
            observations = [
                scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.recompute() },
                scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.recompute() },
            ]
            recompute()
        }

        /// Keep the page fitted to the width when the view resizes (rotation, margin column appearing).
        func refit() {
            guard let view, abs(view.bounds.width - lastWidth) > 0.5 else { recompute(); return }
            lastWidth = view.bounds.width
            view.autoScales = true
            view.scaleFactor = view.scaleFactorForSizeToFit
            recompute()
        }

        @objc private func changed() { recompute() }

        func recompute() {
            guard let view, let doc = view.document, doc === model.document else { return }
            var result: [UUID: NoteGeometry] = [:]
            for note in model.notes {
                let rects = note.lines.compactMap { line -> CGRect? in
                    guard let page = doc.page(at: line.pageIndex) else { return nil }
                    return view.convert(line.bounds, from: page)
                }
                result[note.id] = NoteGeometry(lines: rects)
            }
            var frames: [Int: CGRect] = [:]
            for page in view.visiblePages {
                frames[doc.index(for: page)] = view.convert(page.bounds(for: view.displayBox), from: page)
            }
            model.geometry = result
            model.pageFrames = frames
            if let sel = model.selection, let page = sel.pages.first {
                model.selectionRect = view.convert(sel.bounds(for: page), from: page)
            }
        }

        @objc private func selectionChanged() {
            guard let view else { return }
            if let sel = view.currentSelection, let text = sel.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let page = sel.pages.first {
                model.selection = sel
                model.selectionRect = view.convert(sel.bounds(for: page), from: page)
            } else {
                model.selection = nil
                model.selectionRect = nil
            }
        }

        /// Tapping a marked passage activates its note (and opens it where notes are folded).
        @objc private func tapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: view)
            let hit = model.notes.first { note in
                model.geometry[note.id]?.lines.contains { $0.insetBy(dx: -4, dy: -6).contains(p) } ?? false
            }
            withAnimation(.smooth(duration: 0.3)) {
                guard let hit else { model.active = nil; model.peeked = nil; return }
                model.active = hit.id
                if model.style == .foldedMark {
                    model.toggleFold(hit.id)
                } else if model.mode == .reading {
                    model.peeked = model.peeked == hit.id ? nil : hit.id
                }
            }
        }
    }
}

private final class ReaderPDFView: PDFView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let t = sub as? T { return t }
            if let t = sub.firstSubview(of: type) { return t }
        }
        return nil
    }
}
