import GinkgoAI
import GinkgoCore
import PDFKit
import SwiftUI

/// What a note is waiting for beyond its first answer.
enum NoteActivity {
    case answer, keyItems, analysis, followUp
}

/// AI requests behind the margin notes: the first answer, then follow-up questions, and for a language the
/// reader is learning, a word card or the key expressions and an optional grammar walk-through.
extension ReaderModel {
    /// Runs (or re-runs) an AI task on an existing annotation; the answer streams into its card.
    func run(_ task: AITask, on id: UUID) {
        guard let record = annotation(id), let anchor = record.anchor else { return }
        let before = AnnotationSnapshot(record)
        registerUndo(String(localized: "AI 批注")) { $0.revert(to: before) }
        record.taskRaw = task.tag
        switch task {
        case .ask(let q), .handwritten(let q): record.question = q
        default: break
        }
        record.replyText = nil
        record.replyError = nil
        record.thread = []
        record.study = StudyNote()
        record.replyState = .pending
        peeked.insert(id)
        collapsed.remove(id)
        focused = id

        let settings = AISettings.shared
        let context = passageContext(anchor)
        let learning = task == .translate && settings.isLearning(anchor.quote)
        let level = settings.learnerLevel

        if learning, PassageShape.isLookup(anchor.quote) {
            // A word looked up inside a translated sentence: the card should read it the way that translation does.
            let sentence = parentNote(of: id).flatMap { parent -> (text: String, translation: String)? in
                guard parent.taskRaw == AITask.translate.tag, let quote = parent.anchor?.quote,
                      let translation = parent.replyText, !translation.isEmpty else { return nil }
                return (quote, translation)
            }
            perform(id, .answer) { client in
                let request = PromptBuilder.wordCard(context: context, level: level, sentence: sentence)
                let card = try StudyJSON.decode(WordCard.self, from: try await client.collect(request))
                record.study = StudyNote(word: card)
                record.replyText = card.summary
                record.replyState = .done
            } failed: { message in
                record.replyError = message
                record.replyState = .failed
            }
            return
        }

        let request = PromptBuilder.request(for: task, context: context, learning: learning)
        perform(id, .answer) { [weak self] client in
            var text = ""
            for try await chunk in client.stream(request) {
                text += chunk
                record.replyText = text
                record.replyState = .streaming
            }
            record.replyState = .done
            guard learning, let self else { return }
            try? self.context.save()
            self.busy[id] = .keyItems
            await self.loadKeyItems(record, context: context, translation: text, level: level, client: client)
        } failed: { message in
            record.replyError = message
            record.replyState = .failed
        }
    }

    func retry(_ id: UUID) {
        guard let record = annotation(id) else { return }
        let task: AITask = switch record.taskRaw {
        case "translate": .translate
        case "explain": .explain
        case "handwritten": .handwritten(record.question ?? "")
        default: .ask(record.question ?? "")
        }
        run(task, on: id)
    }

    // MARK: Follow-ups

    /// Asks a further question on a note. The answer streams in under the earlier ones; undo takes the round back.
    func followUp(_ question: String, on id: UUID) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let record = annotation(id), let anchor = record.anchor, record.replyState == .done else { return }
        let before = AnnotationSnapshot(record)
        registerUndo(String(localized: "追问")) { $0.revert(to: before, name: String(localized: "追问")) }
        let history = record.thread.filter { $0.error == nil }
        record.thread = history + [FollowUp(question: question)]
        peeked.insert(id)
        collapsed.remove(id)
        focused = id

        let settings = AISettings.shared
        let study = record.study
        let material = FollowUpMaterial(task: record.taskLabel, question: record.question, answer: record.replyText ?? "",
                                        keyItems: study.keyItems?.items ?? [], analysis: study.analysis?.summary)
        let learning = record.taskRaw == "translate" && settings.isLearning(anchor.quote)
        let request = PromptBuilder.followUp(context: passageContext(anchor), material: material, history: history,
                                             question: question, level: learning ? settings.learnerLevel : nil)
        perform(id, .followUp) { client in
            var text = ""
            for try await chunk in client.stream(request) {
                text += chunk
                record.updateLastTurn { $0.answer = text }
            }
        } failed: { message in
            record.updateLastTurn { $0.error = message }
        }
    }

    /// Asks a failed follow-up again.
    func retryFollowUp(_ id: UUID) {
        guard let record = annotation(id), let last = record.thread.last, last.error != nil else { return }
        record.thread.removeLast()
        followUp(last.question, on: id)
    }

    // MARK: Learning a language

    func retryKeyItems(_ id: UUID) {
        guard let record = annotation(id), let anchor = record.anchor, let translation = record.replyText else { return }
        let context = passageContext(anchor), level = AISettings.shared.learnerLevel
        perform(id, .keyItems) { [weak self] client in
            await self?.loadKeyItems(record, context: context, translation: translation, level: level, client: client)
        } failed: { message in
            record.study.keyItemsError = message
        }
    }

    /// Key expressions are an extra: if they fail, the translation stands and the card offers a retry.
    private func loadKeyItems(_ record: AnnotationRecord, context: PassageContext, translation: String,
                              level: LearnerLevel, client: AIClient) async {
        record.study.keyItemsError = nil
        do {
            let text = try await client.collect(PromptBuilder.keyItems(context: context, translation: translation, level: level))
            record.study.keyItems = try StudyJSON.decode(KeyItems.self, from: text)
        } catch {
            guard !Task.isCancelled else { return }
            record.study.keyItemsError = error.localizedDescription
        }
    }

    /// The grammar walk-through, asked for from the card. Opens the note in full to show it.
    func analyze(_ id: UUID) {
        guard let record = annotation(id), let anchor = record.anchor, let translation = record.replyText else { return }
        let context = passageContext(anchor), level = AISettings.shared.learnerLevel
        let hint = record.study.keyItems?.analysisHint
        record.study.analysisError = nil
        expand(id)
        perform(id, .analysis) { client in
            let text = try await client.collect(PromptBuilder.analysis(context: context, translation: translation, hint: hint, level: level))
            record.study.analysis = try StudyJSON.decode(SentenceAnalysis.self, from: text)
        } failed: { message in
            record.study.analysisError = message
        }
    }

    // MARK: Plumbing

    /// One request at a time per note. A newer one replaces an older; `busy` tells the card what is in flight.
    private func perform(_ id: UUID, _ activity: NoteActivity, _ work: @escaping (AIClient) async throws -> Void,
                         failed: @escaping (String) -> Void) {
        tasks[id]?.cancel()
        busy[id] = activity
        let settings = AISettings.shared
        if settings.needsConsent {
            let provider = settings.provider
            hold(HeldRequest(note: id, send: { [weak self] in self?.perform(id, activity, work, failed: failed) },
                             decline: { [weak self] in
                                 failed(String(localized: "没有发送。同意把文字发给 \(provider.displayName) 后才能回答。"))
                                 self?.busy[id] = nil
                                 try? self?.context.save()
                             }), for: provider)
            return
        }
        tasks[id] = Task { [weak self] in
            do {
                let (client, label) = try AISettings.shared.client()
                if activity == .answer { self?.annotation(id)?.replyModel = label }
                try await work(client)
            } catch {
                guard !Task.isCancelled else { return }
                failed(error.localizedDescription)
                if let detail = (error as? AIError)?.detail { Self.log.error("AI request failed: \(detail, privacy: .public)") }
            }
            guard let self, !Task.isCancelled else { return }
            busy[id] = nil
            tasks[id] = nil
            try? context.save()
        }
    }

    func cancelTask(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        busy[id] = nil
        held.removeAll { $0.note == id }
        if held.isEmpty { askingConsent = nil }
    }

    // MARK: Consent

    /// Keeps a request until the reader answers. A newer request on the same note replaces the older one.
    func hold(_ request: HeldRequest, for provider: AIProviderKind) {
        held.removeAll { $0.note == request.note }
        held.append(request)
        askingConsent = provider
    }

    /// The reader's answer: agreeing sends everything held and isn't asked again for this service.
    func answerConsent(_ agree: Bool) {
        guard let provider = askingConsent else { return }
        askingConsent = nil
        let waiting = held
        held = []
        if agree { AISettings.shared.setConsent(true, for: provider) }
        for request in waiting { agree ? request.send() : request.decline() }
    }

    private func passageContext(_ anchor: GinkgoCore.Anchor) -> PassageContext {
        PassageContext(bookTitle: book.title, passage: anchor.quote, surrounding: surroundingText(of: anchor),
                       readerLanguage: AISettings.shared.readerLanguage)
    }
}

/// An AI request held until the reader says whether text may go to the AI service.
struct HeldRequest {
    let note: UUID
    let send: () -> Void
    let decline: () -> Void
}

extension AnnotationRecord {
    func updateLastTurn(_ change: (inout FollowUp) -> Void) {
        var turns = thread
        guard !turns.isEmpty else { return }
        change(&turns[turns.count - 1])
        thread = turns
    }
}
