import GinkgoAI
import GinkgoCore
import PencilKit
import SwiftUI

/// One note's conversation in the side column: the passage and first answer at the top, every follow-up round
/// below in order, and a box at the bottom to keep asking. It stays about this passage; there is no free chat.
/// Wide windows dock it beside the page; narrow ones float it over the right side.
struct ConversationPanel: View {
    let model: ReaderModel
    let record: AnnotationRecord
    var width: CGFloat
    var docked: Bool

    @State private var draft = ""
    @FocusState private var typing: Bool

    private var activity: NoteActivity? { model.busy[record.id] }
    private var canAsk: Bool { record.replyState == .done && activity == nil }
    private var bottomID: String { "end-\(record.id)" }

    var body: some View {
        VStack(spacing: 0) {
            header
            NoteParts.divider
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.section) {
                        NoteCard(model: model, record: record, width: width - Theme.cardInset * 2, showsThread: false)
                        ForEach(Array(record.thread.enumerated()), id: \.offset) { offset, turn in
                            ConversationTurn(turn: turn, color: record.color, width: width - Theme.cardInset * 2,
                                             waiting: offset == record.thread.count - 1 && activity == .followUp,
                                             retry: offset == record.thread.count - 1 ? { model.retryFollowUp(record.id) } : nil)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(Theme.cardInset)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
                .onChange(of: record.thread.count) { _, _ in
                    withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: record.thread.last?.answer.count) { _, _ in proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            NoteParts.divider
            composer
        }
        .frame(width: width)
        .background(docked ? Theme.margin : Theme.paper)
        .background(BackSwipeBlocker())
        // A swipe to the right puts the column away, the reverse of the swipe that brought it in.
        .simultaneousGesture(DragGesture(minimumDistance: Theme.Conversation.edgeSwipe).onEnded { drag in
            let t = drag.translation
            guard t.width > Theme.Conversation.dismissSwipe, abs(t.height) < t.width / 2 else { return }
            typing = false
            withAnimation(.smooth(duration: 0.3)) { model.closeConversation() }
        })
        .onAppear(perform: takeFocusIfAsked)
        .onChange(of: record.id) { _, _ in
            draft = ""
            takeFocusIfAsked()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.rhythm) {
            // The passage this conversation is about; the card below carries the colour and kind.
            Text(record.anchor?.quote ?? "")
                .font(Theme.quoteFont)
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(3)
                .padding(.leading, Theme.Space.medium)
                .overlay(alignment: .leading) {
                    Rectangle().fill(record.color.ink.opacity(Theme.quoteRuleOpacity)).frame(width: Theme.noteRuleWidth)
                }
            Spacer(minLength: 0)
            Button { withAnimation(.smooth(duration: 0.3)) { model.closeConversation() } } label: {
                Image(systemName: "xmark").font(Theme.panelIconFont)
                    .frame(width: Theme.panelControlSize, height: Theme.panelControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryInk)
            .accessibilityLabel("收起")
        }
        .padding(.horizontal, Theme.cardInset)
        .padding(.vertical, Theme.Space.medium)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.regular) {
            TextField(canAsk ? "接着问，比如：能再举个例子吗？" : "等回答完成后可以接着问", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .font(Theme.noteFont)
                .padding(.horizontal, Theme.Space.medium)
                .padding(.vertical, Theme.Space.regular)
                .background(RoundedRectangle(cornerRadius: Theme.Conversation.fieldRadius).fill(Theme.card))
                .overlay { RoundedRectangle(cornerRadius: Theme.Conversation.fieldRadius).strokeBorder(Theme.rule, lineWidth: Theme.hairline) }
                .disabled(!canAsk)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.Conversation.sendFont)
                    .foregroundStyle(sendable ? record.color.ink : Theme.rule)
            }
            .buttonStyle(.plain)
            .disabled(!sendable)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("发送追问")
        }
        .padding(Theme.Space.medium)
    }

    private var sendable: Bool { canAsk && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard sendable else { return }
        model.followUp(draft, on: record.id)
        draft = ""
    }

    private func takeFocusIfAsked() {
        guard model.composeOnOpen else { return }
        model.composeOnOpen = false
        DispatchQueue.main.async { typing = true }
    }
}

/// One follow-up round: the question as the reader's bubble on the right, the answer as plain text below.
private struct ConversationTurn: View {
    let turn: FollowUp
    let color: HighlightColor
    let width: CGFloat
    var waiting: Bool
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.regular) {
            HStack {
                Spacer(minLength: width * 0.18)
                Text(turn.question)
                    .font(Theme.questionFont)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.medium)
                    .padding(.vertical, Theme.Space.regular)
                    .background(RoundedRectangle(cornerRadius: Theme.Conversation.bubbleRadius).fill(color.fill.opacity(Theme.Conversation.bubbleOpacity)))
                    .textSelection(.enabled)
            }
            if !turn.answer.isEmpty {
                Text(turn.answer)
                    .font(Theme.noteFont)
                    .lineSpacing(Theme.lineSpacing)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if waiting {
                ThinkingDots(color: color.ink)
            } else if let retry {
                NoteParts.failure(turn.error ?? String(localized: "没有拿到回答。"), retry: retry)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

extension ReaderModel {
    /// Opens a note's conversation in the side column; `compose` puts the cursor in the box to ask at once.
    func openConversation(_ id: UUID, compose: Bool = false) {
        guard annotation(id)?.hasNote == true else { return }
        lastOpened = id
        composeOnOpen = compose
        peeked.remove(id)  // the floating card would only repeat what the column shows
        collapsed.remove(id)
        expanded = id
        focused = id
    }

    /// The swipe in from the right edge: the note being read (focused, else the last one opened, if it is still on
    /// screen), else the first note on screen. A page with no notes on it ignores the swipe.
    func revealSideColumn() {
        guard expanded == nil else { return }
        let onScreen = notes.filter { geometry[$0.id] != nil }
        let target = [focused, lastOpened].compactMap { $0 }.first { id in onScreen.contains { $0.id == id } }
            ?? onScreen.min { (geometry[$0.id]?.first.minY ?? 0) < (geometry[$1.id]?.first.minY ?? 0) }?.id
        guard let target else { return }
        openConversation(target)
    }

    func closeConversation() {
        expanded = nil
        composeOnOpen = false
    }
}

/// Turns off iOS 26's swipe-anywhere back gesture while it is on screen, so a swipe to the right inside the
/// conversation closes the column instead of leaving the book. The back button still works.
struct BackSwipeBlocker: UIViewRepresentable {
    func makeUIView(context: Context) -> BlockerView { BlockerView() }
    func updateUIView(_ view: BlockerView, context: Context) {}

    final class BlockerView: UIView {
        /// Blockers on screen per gesture, so the scratch sheet and the column can both hold it off.
        nonisolated(unsafe) private static var holds: [ObjectIdentifier: Int] = [:]
        private weak var gesture: UIGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { release(); return }
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil, gesture == nil else { return }
                let nav = sequence(first: self as UIResponder, next: \.next).lazy.compactMap { $0 as? UINavigationController }.first
                guard let pop = nav?.interactiveContentPopGestureRecognizer else { return }
                gesture = pop
                Self.holds[ObjectIdentifier(pop), default: 0] += 1
                pop.isEnabled = false
            }
        }

        private func release() {
            guard let pop = gesture else { return }
            let key = ObjectIdentifier(pop)
            Self.holds[key, default: 1] -= 1
            if Self.holds[key, default: 0] <= 0 {
                Self.holds[key] = nil
                pop.isEnabled = true
            }
            gesture = nil
        }
    }
}
