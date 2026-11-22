import GinkgoCore
import PencilKit
import SwiftData
import SwiftUI

/// Everything stored on an annotation, so a deleted one can come back as it was (same id, same AI answer)
/// without asking the AI again.
struct AnnotationSnapshot {
    let id: UUID
    let kindRaw: String
    let colorRaw: String
    let styleRaw: String?
    let anchorData: Data?
    let createdAt: Date
    let inkData: Data?
    let question: String?
    let taskRaw: String?
    let replyText: String?
    let replyStateRaw: String?
    let replyError: String?
    let replyModel: String?

    init(_ r: AnnotationRecord) {
        id = r.id; kindRaw = r.kindRaw; colorRaw = r.colorRaw; styleRaw = r.styleRaw; anchorData = r.anchorData
        createdAt = r.createdAt; inkData = r.inkData; question = r.question; taskRaw = r.taskRaw
        replyText = r.replyText; replyError = r.replyError; replyModel = r.replyModel
        // An answer still arriving when the snapshot was taken comes back as failed, with a retry, not stuck.
        let state = r.replyState
        replyStateRaw = (state == .pending || state == .streaming) && r.replyText?.isEmpty != false
            ? ReplyState.failed.rawValue : (state == .streaming ? ReplyState.done.rawValue : r.replyStateRaw)
    }

    func apply(to r: AnnotationRecord) {
        r.kindRaw = kindRaw; r.colorRaw = colorRaw; r.styleRaw = styleRaw; r.anchorData = anchorData
        r.createdAt = createdAt; r.inkData = inkData; r.question = question; r.taskRaw = taskRaw
        r.replyText = replyText; r.replyStateRaw = replyStateRaw; r.replyModel = replyModel
        r.replyError = replyStateRaw == ReplyState.failed.rawValue ? (replyError ?? "回答被撤销了，可以重试。") : replyError
    }
}

/// Undo and redo for everything the reader changes: marks, notes, colours and page ink. All of it goes through the
/// window's undo manager, so the system gestures (three-finger swipe, the three-finger tap menu) and ⌘Z work.
extension ReaderModel {
    var undoManager: UndoManager? { pdfView?.undoManager }

    func registerUndo(_ name: String, _ action: @escaping (ReaderModel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { action(model) }
        }
        undoManager.setActionName(name)
        refreshUndoState()
    }

    /// Undo of a newly made annotation: delete it (which in turn registers its restore as the redo).
    func registerRemoval(of id: UUID, name: String) {
        registerUndo(name) { $0.delete(id) }
    }

    /// Brings back a deleted annotation.
    func restore(_ snapshot: AnnotationSnapshot) {
        guard annotation(snapshot.id) == nil else { return }
        let record = AnnotationRecord(kind: .highlight, anchor: .pdf(PDFAnchor(pageIndex: 0, rects: [], quote: "")))
        record.id = snapshot.id
        snapshot.apply(to: record)
        record.book = book
        context.insert(record)
        registerRemoval(of: record.id, name: "删除批注")
        try? context.save()
        reload()
    }

    /// Puts an annotation's fields back (an AI note becomes the plain mark it was, or gets its old answer back).
    func revert(to snapshot: AnnotationSnapshot) {
        guard let record = annotation(snapshot.id) else { return }
        tasks[snapshot.id]?.cancel()
        let current = AnnotationSnapshot(record)
        registerUndo("AI 批注") { $0.revert(to: current) }
        snapshot.apply(to: record)
        if !record.hasNote { peeked.remove(record.id); if expanded == record.id { expanded = nil } }
        try? context.save()
        reload()
    }

    /// Page ink changed (strokes kept, erased, or turned into marks): undo puts the old drawing back.
    func registerInkChange(page: Int, from old: PKDrawing, to new: PKDrawing) {
        registerUndo("笔迹") { model in
            model.pageInk.setDrawing(old, page: page)
            model.registerInkChange(page: page, from: new, to: old)
        }
    }

    func undo() { undoManager?.undo(); refreshUndoState() }
    func redo() { undoManager?.redo(); refreshUndoState() }

    func refreshUndoState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            canUndo = undoManager?.canUndo ?? false
            canRedo = undoManager?.canRedo ?? false
        }
    }
}
