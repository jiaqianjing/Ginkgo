import PDFKit
import PencilKit
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
        view.pencilInteraction.delegate = context.coordinator
        view.addInteraction(view.pencilInteraction)
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        view.addGestureRecognizer(hover)
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

        let mark = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.marking(_:)))
        mark.maximumNumberOfTouches = 1
        mark.delegate = c
        mark.name = "ginkgo.mark"
        view.addGestureRecognizer(mark)
        c.markGesture = mark

        let twoFinger = UITapGestureRecognizer(target: c, action: #selector(Coordinator.twoFingerTapped(_:)))
        twoFinger.numberOfTouchesRequired = 2
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFinger.delegate = c
        view.addGestureRecognizer(twoFinger)
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
            center.addObserver(c, selector: #selector(Coordinator.undoChanged), name: name, object: nil)
        }

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = c
        view.addGestureRecognizer(tap)
        DispatchQueue.main.async {
            c.attachScrollObserver(view)
            view.reserveTouches(tool: model.tool != nil, fingersDraw: model.fingersDraw)
        }
        return view
    }

    func updateUIView(_ view: ReaderPDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        let model: ReaderModel
        var onPageChange: (Int) -> Void
        private var observations: [NSKeyValueObservation] = []
        weak var markGesture: UIPanGestureRecognizer?
        private var markStart: (page: PDFPage, point: CGPoint)?

        init(model: ReaderModel, onPageChange: @escaping (Int) -> Void) {
            self.model = model
            self.onPageChange = onPageChange
        }

        /// PDFKit scrolls an internal UIScrollView; follow it so margin notes move with the text.
        func attachScrollObserver(_ view: PDFView) {
            guard let scroll = view.firstSubview(of: UIScrollView.self) else { return }
            // A live mark wins over scrolling; it fails at once when no marking tool is chosen, so scrolling is not delayed.
            if let markGesture { scroll.panGestureRecognizer.require(toFail: markGesture) }
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
            if model.selectionFromPencil && selection == nil && model.selection != nil { return }
            model.selectionChanged(selection)
        }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage,
                  let index = view.document?.index(for: page) else { return }
            onPageChange(index)
            model.recompute()
        }

        @objc func undoChanged() { model.refreshUndoState() }

        /// Two-finger tap undoes while a Pencil tool is in hand (a common note-app gesture; can be turned off).
        @objc func twoFingerTapped(_ gesture: UITapGestureRecognizer) {
            let enabled = UserDefaults.standard.object(forKey: "gesture.twoFingerUndo") as? Bool ?? true
            guard enabled, model.tool != nil, model.canUndo else { return }
            withAnimation(.smooth(duration: 0.2)) { model.undo() }
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
            if model.expanded != nil || (model.mode == .reading && !model.peeked.isEmpty) {
                withAnimation(.smooth(duration: 0.25)) { model.foldAll() }
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
            g !== markGesture && other !== markGesture
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            g === markGesture ? model.marksLive : true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard g === markGesture else { return true }
            #if targetEnvironment(simulator)
            return true
            #else
            return touch.type == .pencil || (model.fingersDraw && touch.type == .direct)
            #endif
        }

        // MARK: Live marks

        /// Highlighter and underline follow the text from where the Pencil landed to where it is now, like dragging
        /// a text selection, and the mark is shown as it will be saved. Lifting the Pencil keeps it.
        @objc func marking(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? PDFView, let tool = model.tool else { return }
            let underline = tool == .underline
            switch g.state {
            case .began:
                let p = g.location(in: view)
                guard let page = view.page(for: p, nearest: true) else { return }
                markStart = (page, textPoint(near: view.convert(p, to: page), on: page, underline: underline))
                update(g, in: view, underline: underline)
            case .changed:
                update(g, in: view, underline: underline)
            case .ended:
                update(g, in: view, underline: underline)
                if let preview = model.markPreview {
                    withAnimation(.smooth(duration: 0.15)) {
                        _ = model.highlight(preview.selection, color: preview.color, style: preview.style)
                    }
                }
                model.markPreview = nil
                markStart = nil
            default:
                model.markPreview = nil
                markStart = nil
            }
        }

        private func update(_ g: UIPanGestureRecognizer, in view: PDFView, underline: Bool) {
            guard let start = markStart else { return }
            let end = textPoint(near: view.convert(g.location(in: view), to: start.page), on: start.page, underline: underline)
            guard let selection = start.page.selection(from: start.point, to: end) else { model.markPreview = nil; return }
            // Whole words at both ends, as text selection does; a mark never stops mid-word.
            for point in [start.point, end] {
                if let word = start.page.selectionForWord(at: point), word.string?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    selection.add(word)
                }
            }
            guard selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                model.markPreview = nil
                return
            }
            let lines = selection.selectionsByLine().map { view.convert($0.bounds(for: start.page), from: start.page) }
                .filter { $0.width > 0.5 && $0.height > 0.5 }
            model.markPreview = MarkPreview(lines: lines, style: underline ? model.underlineStyle : .highlight,
                                            color: model.markColor, selection: selection)
        }

        /// The nearest point on text: an underline is drawn under its line, so look a little above the tip first.
        private func textPoint(near p: CGPoint, on page: PDFPage, underline: Bool) -> CGPoint {
            // Page space has y growing up: positive offsets look above the tip.
            let offsets: [CGFloat] = underline ? [4, 7, 10, 2, 13, 0, 16] : [0, 3, -3, 6, -6]
            for dy in offsets {
                let q = CGPoint(x: p.x, y: p.y + dy)
                let index = page.characterIndex(at: q)
                if index >= 0, index != NSNotFound { return q }
            }
            return underline ? CGPoint(x: p.x, y: p.y + 6) : p
        }

        // MARK: Apple Pencil

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            withAnimation(.smooth(duration: 0.2)) { model.pencilTapped(UIPencilInteraction.preferredTapAction) }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended, let view = interaction.view else { return }
            let point = squeeze.hoverPose.map { view.convert($0.location, to: model.pdfView) }
            withAnimation(.smooth(duration: 0.2)) {
                model.pencilSqueezed(at: point, action: UIPencilInteraction.preferredSqueezeAction)
            }
        }

        @objc func hovered(_ g: UIHoverGestureRecognizer) {
            switch g.state {
            case .began, .changed: model.hoverPoint = model.tool == nil ? nil : g.location(in: g.view)
            default: model.hoverPoint = nil
            }
        }
    }
}

/// Keeps pages fitted to the width when the view is resized (rotation, Split View, Stage Manager), and tells the
/// model so margin notes can follow.
final class ReaderPDFView: PDFView {
    var onLayout: (() -> Void)?
    private var lastWidth: CGFloat = 0
    let pencilInteraction = UIPencilInteraction()

    // First responder, so ⌘Z and the system three-finger undo gestures reach the window's undo manager.
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() } }
    }
    private var savedTouchTypes: [ObjectIdentifier: [NSNumber]] = [:]

    /// While a tool is chosen, PDFKit's own gestures (scrolling, text selection) leave the drawing input to the tool:
    /// with Pencil-only drawing they take only fingers; when fingers draw too, one finger belongs to the tool, so
    /// scrolling needs two fingers and text selection waits until the tool is put down. Pinch-zoom always works.
    /// The simulator's mouse is both finger and Pencil, so it is left alone there.
    func reserveTouches(tool: Bool, fingersDraw: Bool) {
        #if !targetEnvironment(simulator)
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let none = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let scroll = firstSubview(of: UIScrollView.self)
        func visit(_ view: UIView) {
            if view is PKCanvasView { return }
            for g in view.gestureRecognizers ?? [] where !(g is UIHoverGestureRecognizer) && !(g.delegate is PDFKitView.Coordinator) {
                let key = ObjectIdentifier(g)
                if savedTouchTypes[key] == nil { savedTouchTypes[key] = g.allowedTouchTypes }
                guard tool else { g.allowedTouchTypes = savedTouchTypes[key] ?? g.allowedTouchTypes; continue }
                if g === scroll?.panGestureRecognizer || g === scroll?.pinchGestureRecognizer {
                    g.allowedTouchTypes = fingers
                } else {
                    g.allowedTouchTypes = fingersDraw ? none : fingers
                }
            }
            view.subviews.forEach(visit)
        }
        visit(self)
        scroll?.panGestureRecognizer.minimumNumberOfTouches = tool && fingersDraw ? 2 : 1
        if !tool { savedTouchTypes.removeAll() }
        #endif
    }

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
