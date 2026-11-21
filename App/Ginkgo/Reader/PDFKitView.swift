import PDFKit
import SwiftUI

/// PDFKit's view in SwiftUI. Reports page, selection, scroll and zoom changes to the model, and routes taps:
/// a tap on a highlight focuses it, a tap elsewhere ends a selection or toggles the chrome.
struct PDFKitView: UIViewRepresentable {
    let model: ReaderModel
    var onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onPageChange: onPageChange) }

    func makeUIView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = UIColor(Theme.desk)
        view.pageOverlayViewProvider = model.pageInk
        view.document = model.document
        model.pdfView = view
        let doc = model.document
        if let page = doc.page(at: min(model.book.lastPageIndex, max(doc.pageCount - 1, 0))) {
            view.go(to: page)
        }

        let c = context.coordinator
        view.onLayout = { [weak c] in c?.layoutChanged() }
        let center = NotificationCenter.default
        center.addObserver(c, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view)
        center.addObserver(c, selector: #selector(Coordinator.geometryChanged), name: .PDFViewScaleChanged, object: view)
        center.addObserver(c, selector: #selector(Coordinator.geometryChanged), name: .PDFViewVisiblePagesChanged, object: view)
        center.addObserver(c, selector: #selector(Coordinator.selectionChanged), name: .PDFViewSelectionChanged, object: view)

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = c
        view.addGestureRecognizer(tap)
        DispatchQueue.main.async { c.attachScrollObserver(view) }
        return view
    }

    func updateUIView(_ view: ReaderPDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: ReaderModel
        var onPageChange: (Int) -> Void
        private var observations: [NSKeyValueObservation] = []

        init(model: ReaderModel, onPageChange: @escaping (Int) -> Void) {
            self.model = model
            self.onPageChange = onPageChange
        }

        /// PDFKit scrolls an internal UIScrollView; follow it so margin notes move with the text.
        func attachScrollObserver(_ view: PDFView) {
            guard let scroll = view.firstSubview(of: UIScrollView.self) else { return }
            observations = [
                scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.model.recompute() }
                },
                scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.model.recompute() }
                },
            ]
            model.recompute()
        }

        func layoutChanged() { model.recompute() }

        @objc func geometryChanged() { model.recompute() }

        @objc func selectionChanged(_ note: Notification) {
            let selection = (note.object as? PDFView)?.currentSelection
            // In writing mode PDFKit drops selections we set from a Pencil loop; keep ours until the reader acts.
            if model.penOn && selection == nil && model.selection != nil { return }
            model.selectionChanged(selection)
        }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage,
                  let index = view.document?.index(for: page) else { return }
            onPageChange(index)
            model.recompute()
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PDFView else { return }
            let point = gesture.location(in: view)
            if let id = model.annotation(at: point) {
                // A note opens or folds its card; a plain highlight shows or hides its menu.
                withAnimation(.smooth(duration: 0.25)) {
                    if model.annotation(id)?.hasNote == true {
                        model.toggle(id)
                    } else {
                        model.focused = model.focused == id ? nil : id
                    }
                }
                return
            }
            if model.selection != nil || view.currentSelection != nil {
                model.clearSelection()
                return
            }
            if model.focused != nil {
                withAnimation(.smooth(duration: 0.2)) { model.focused = nil }
                return
            }
            if let page = view.page(for: point, nearest: false) {
                let annotation = page.annotation(at: view.convert(point, to: page))
                if annotation?.url != nil || annotation?.destination != nil { return }
            }
            withAnimation(.easeInOut(duration: 0.2)) { model.chromeVisible.toggle() }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Keeps pages fitted to the width when the view is resized (rotation, Split View, Stage Manager), and tells the
/// model so margin notes can follow.
final class ReaderPDFView: PDFView {
    var onLayout: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            let page = currentPage
            minScaleFactor = scaleFactorForSizeToFit * 0.5
            maxScaleFactor = scaleFactorForSizeToFit * 5
            scaleFactor = scaleFactorForSizeToFit
            if let page { go(to: page) }
        }
        onLayout?()
    }
}

extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T { return match }
            if let match = sub.firstSubview(of: type) { return match }
        }
        return nil
    }
}
