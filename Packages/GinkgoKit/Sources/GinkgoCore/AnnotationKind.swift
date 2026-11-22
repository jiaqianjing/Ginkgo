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

/// How a mark on the text is drawn. Raw values are stored, so never rename a case.
public enum MarkStyle: String, Codable, CaseIterable, Sendable {
    /// Marker fill over the line.
    case highlight
    /// A straight rule under the line.
    case underline
    /// A wavy rule under the line.
    case squiggly
}
