/// What the reader did to a passage.
public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case highlight
    case ink
    case question
}

/// Highlight palette. Raw values are stored, so never rename a case.
public enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink, violet
}
