import GinkgoAI
import SwiftUI

/// Pieces of a note card beyond the plain answer: the word card, key expressions, the grammar walk-through and
/// follow-up rounds.
enum NoteParts {
    /// How many key expressions the floating card shows before "展开全文".
    static let compactKeyItems = 2

    static var divider: some View {
        Rectangle().fill(Theme.rule).frame(height: Theme.hairline)
    }

    /// A passage short enough for a link or chip.
    static func excerpt(_ text: String, limit: Int = 18) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    static func heading(_ text: String) -> some View {
        Text(text).font(Theme.labelFont).foregroundStyle(Theme.secondaryInk)
    }

    static func progress(_ text: String) -> some View {
        Text(text).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
    }

    static func failure(_ text: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.compact) {
            Text(text).font(Theme.captionFont).foregroundStyle(Theme.error).lineLimit(2)
            Spacer(minLength: 0)
            Button("重试", action: retry).font(Theme.actionFont).buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
    }
}

/// A learner's dictionary entry for the selected word, read in its context.
struct WordCardView: View {
    let card: WordCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.compact) {
                Text(card.term ?? "").font(Theme.termFont).foregroundStyle(Theme.ink)
                if let phonetic = card.phonetic, !phonetic.isEmpty {
                    Text(phonetic).font(Theme.footnoteFont).foregroundStyle(Theme.secondaryInk)
                }
            }
            if let lemma = card.lemma, !lemma.isEmpty, lemma.lowercased() != card.term?.lowercased() {
                Text("原形 \(lemma)").font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
            }
            if let meaning = card.contextMeaning, !meaning.isEmpty {
                Text(meaning).font(Theme.noteFont.weight(.semibold)).foregroundStyle(Theme.ink)
            }
            ForEach(Array((card.senses ?? []).enumerated()), id: \.offset) { _, sense in
                if let meaning = sense.meaning, !meaning.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.compact) {
                        Text(sense.pos ?? "").font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                            .frame(minWidth: 28, alignment: .leading)
                        Text(meaning).font(Theme.footnoteFont).foregroundStyle(Theme.ink)
                    }
                }
            }
            if let source = card.example?.source, !source.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source).font(Theme.footnoteFont).italic().foregroundStyle(Theme.ink)
                    if let target = card.example?.target, !target.isEmpty {
                        Text(target).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                    }
                }
                .padding(.top, 2)
            }
            if let note = card.note, !note.isEmpty {
                Label(note, systemImage: "lightbulb").font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

/// Expressions in the sentence worth remembering.
struct KeyItemsView: View {
    let items: [KeyItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.compact) {
            NoteParts.heading("重点表达")
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.compact) {
                        Text(item.text).font(Theme.questionFont).foregroundStyle(Theme.ink)
                        if let phonetic = item.phonetic, !phonetic.isEmpty {
                            Text(phonetic).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                        }
                        if let kind = item.kindLabel {
                            Text(kind).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.margin))
                        }
                    }
                    if let meaning = item.meaning, !meaning.isEmpty {
                        Text(meaning).font(Theme.footnoteFont).foregroundStyle(Theme.ink)
                    }
                    if let note = item.note, !note.isEmpty {
                        Text(note).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

/// A teacher's walk through the sentence: its skeleton, its parts, and what to take away.
struct AnalysisView: View {
    let analysis: SentenceAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.compact) {
            NoteParts.heading("语法分析")
            if let skeleton = analysis.skeleton, !skeleton.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("主干").font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                    Text(skeleton).font(Theme.questionFont).foregroundStyle(Theme.ink)
                    if let t = analysis.skeletonTranslation, !t.isEmpty {
                        Text(t).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
            ForEach(Array((analysis.chunks ?? []).enumerated()), id: \.offset) { _, chunk in
                if let text = chunk.text, !text.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.compact) {
                            Text(text).font(Theme.footnoteFont.weight(.medium)).foregroundStyle(Theme.ink)
                            if let role = chunk.role, !role.isEmpty {
                                Text(role).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.margin))
                            }
                        }
                        if let explain = chunk.explain, !explain.isEmpty {
                            Text(explain).font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                }
            }
            ForEach(Array((analysis.insights ?? []).enumerated()), id: \.offset) { _, insight in
                if !insight.isEmpty {
                    Label(insight, systemImage: "checkmark").font(Theme.footnoteFont).foregroundStyle(Theme.ink)
                }
            }
            if let usage = analysis.usage, !usage.isEmpty {
                Text(usage).font(Theme.footnoteFont).foregroundStyle(Theme.ink)
            }
            if let paraphrase = analysis.paraphrase, !paraphrase.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("换个说法").font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                    Text(paraphrase).font(Theme.footnoteFont).italic().foregroundStyle(Theme.ink)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

/// One follow-up round: the question, then its answer as it streams in.
struct FollowUpView: View {
    let turn: FollowUp
    var waiting: Bool
    var lineLimit: Int?
    /// Only the latest round can be asked again.
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.compact) {
            Label(turn.question, systemImage: "arrow.turn.down.right")
                .font(Theme.questionFont)
                .foregroundStyle(Theme.ink)
            if !turn.answer.isEmpty {
                Text(turn.answer)
                    .font(Theme.noteFont)
                    .lineSpacing(Theme.lineSpacing)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if waiting {
                NoteParts.progress("正在思考…")
            } else if let retry {
                NoteParts.failure(turn.error ?? "没有拿到回答。", retry: retry)
            }
        }
    }
}
