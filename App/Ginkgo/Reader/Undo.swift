import GinkgoAI
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
    let threadData: Data?
    let studyData: Data?

    init(_ r: AnnotationRecord) {
        id = r.id; kindRaw = r.kindRaw; colorRaw = r.colorRaw; styleRaw = r.styleRaw; anchorData = r.anchorData
        createdAt = r.createdAt; inkData = r.inkData; question = r.question; taskRaw = r.taskRaw
        replyText = r.replyText; replyError = r.replyError; replyModel = r.replyModel
        threadData = Self.settled(r.thread).flatMap { $0.isEmpty ? nil : StudyJSON.encode($0) }
        studyData = r.studyData
        // An answer still arriving when the snapshot was taken comes back as failed, with a retry, not stuck.
        let state = r.replyState
        replyStateRaw = (state == .pending || state == .streaming) && r.replyText?.isEmpty != false
            ? ReplyState.failed.rawValue : (state == .streaming ? ReplyState.done.rawValue : r.replyStateRaw)
    }

    func apply(to r: AnnotationRecord) {
        r.kindRaw = kindRaw; r.colorRaw = colorRaw; r.styleRaw = styleRaw; r.anchorData = anchorData
        r.createdAt = createdAt; r.inkData = inkData; r.question = question; r.taskRaw = taskRaw
        r.replyText = replyText; r.replyStateRaw = replyStateRaw; r.replyModel = replyModel
        r.threadData = threadData; r.studyData = studyData
        r.replyError = replyStateRaw == ReplyState.failed.rawValue ? (replyError ?? "回答被撤销了，可以重试。") : replyError
    }

    /// A follow-up still waiting for its answer comes back as failed, like the main reply.
    private static func settled(_ thread: [FollowUp]) -> [FollowUp]? {
        thread.map { turn in
            var turn = turn
            if turn.answer.isEmpty, turn.error == nil { turn.error = "回答被撤销了，可以重试。" }
            return turn
        }
    }
}

/// Undo and redo for everything the reader changes: marks, notes, colours and page ink. All of it goes through the
/// window's undo manager, so the system gestures (three-finger swipe, the three-finger tap menu) and ⌘Z work.
extension ReaderModel {
    /// The book's undo manager. Changes to the book always register here, even while the scratch sheet is open.
    var bookUndoManager: UndoManager? { pdfView?.undoManager }
    /// What undo and redo act on now: the scratch sheet while it is open, otherwise the book.
    var undoManager: UndoManager? { showScratch ? scratchUndo : bookUndoManager }

    func registerUndo(_ name: String, _ action: @escaping (ReaderModel) -> Void) {
        guard let undoManager = bookUndoManager else { return }
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
    func revert(to snapshot: AnnotationSnapshot, name: String = "AI 批注") {
        guard let record = annotation(snapshot.id) else { return }
        cancelTask(snapshot.id)
        let current = AnnotationSnapshot(record)
        registerUndo(name) { $0.revert(to: current, name: name) }
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

    /// Every annotation in the book, ink included, as it is now.
    var allRecords: [AnnotationRecord] { book.annotations ?? [] }

    /// Back to the book as imported, as one undoable step: undo brings every mark, note (with its answer) and
    /// page of ink back.
    func clearAll() {
        let snapshots = allRecords.map(AnnotationSnapshot.init)
        guard !snapshots.isEmpty else { return }
        for record in allRecords {
            cancelTask(record.id)
            if record.kind == .ink, case .pdf(let a)? = record.anchor { pageInk.clearCanvas(page: a.pageIndex) }
            context.delete(record)
        }
        try? context.save()
        focused = nil
        peeked.removeAll()
        collapsed.removeAll()
        expanded = nil
        clearSelection()
        registerUndo("清除全部批注") { $0.restoreAll(snapshots) }
        reload()
    }

    private func restoreAll(_ snapshots: [AnnotationSnapshot]) {
        for snapshot in snapshots where annotation(snapshot.id) == nil {
            let record = AnnotationRecord(kind: .highlight, anchor: .pdf(PDFAnchor(pageIndex: 0, rects: [], quote: "")))
            record.id = snapshot.id
            snapshot.apply(to: record)
            record.book = book
            context.insert(record)
            if record.kind == .ink, case .pdf(let a)? = record.anchor, let data = record.inkData,
               let drawing = try? PKDrawing(data: data) {
                pageInk.showOnCanvas(drawing, page: a.pageIndex)
            }
        }
        try? context.save()
        registerUndo("清除全部批注") { $0.clearAll() }
        reload()
    }

    /// Ink still waiting to be read is settled first, so undo takes back the last thing done, not the one before.
    func undo() { pageInk.flushPending(); undoManager?.undo(); refreshUndoState() }
    func redo() { pageInk.flushPending(); undoManager?.redo(); refreshUndoState() }

    func refreshUndoState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            canUndo = undoManager?.canUndo ?? false
            canRedo = undoManager?.canRedo ?? false
        }
    }
}
