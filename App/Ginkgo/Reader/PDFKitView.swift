import PDFKit
import SwiftUI

/// PDFKit's view in SwiftUI: continuous vertical scrolling, fit to width, page changes and taps reported back.
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let initialPage: Int
    var onPageChange: (Int) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FitWidthPDFView {
        let view = FitWidthPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        if let page = document.page(at: min(initialPage, max(document.pageCount - 1, 0))) {
            view.go(to: page)
        }

        let c = context.coordinator
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: view)
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = c
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: FitWidthPDFView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView

        init(_ parent: PDFKitView) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage,
                  let index = view.document?.index(for: page) else { return }
            parent.onPageChange(index)
        }

        /// A plain tap toggles the chrome, but not one that ends a text selection or follows a link.
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PDFView else { return }
            if view.currentSelection != nil {
                view.clearSelection()
                return
            }
            let point = gesture.location(in: view)
            if let page = view.page(for: point, nearest: false),
               page.annotation(at: view.convert(point, to: page))?.url != nil
                || page.annotation(at: view.convert(point, to: page))?.destination != nil {
                return
            }
            parent.onTap()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Keeps pages fitted to the width when the view is resized (rotation, Split View, Stage Manager).
final class FitWidthPDFView: PDFView {
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, abs(bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = bounds.width
        let page = currentPage
        minScaleFactor = scaleFactorForSizeToFit * 0.5
        maxScaleFactor = scaleFactorForSizeToFit * 5
        scaleFactor = scaleFactorForSizeToFit
        if let page { go(to: page) }
    }
}
