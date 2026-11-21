import Foundation

/// Parsed search query (AST). Produced by `QueryParser` and by the natural
/// language translator; consumed by `SearchSQLBuilder`.
public struct SearchQuery: Equatable, Sendable {
    public var terms: [SearchTerm]
    public var filters: [SearchFilter]

    public init(terms: [SearchTerm] = [], filters: [SearchFilter] = []) {
        self.terms = terms
        self.filters = filters
    }

    public var isEmpty: Bool { terms.isEmpty && filters.isEmpty }
    public var hasText: Bool { terms.contains { !$0.isInert } }
}

public enum SearchTerm: Equatable, Sendable {
    case word(String)
    case phrase(String)

    public var text: String {
        switch self { case .word(let s), .phrase(let s): s }
    }

    /// Terms with no letters/digits can't match anything in FTS.
    var isInert: Bool { !text.contains { $0.isLetter || $0.isNumber } }
}

public enum SearchFilter: Equatable, Sendable {
    case type(ItemType)
    /// User-defined custom type by name (schema v3).
    case customType(String)
    case tag(String)
    case after(Date)
    case before(Date)
    case color(String)
    case meta(key: String, op: MetaOperator, value: MetaValue)
}

public enum MetaOperator: String, CaseIterable, Sendable {
    case eq = "="
    case ne = "!="
    case lt = "<"
    case le = "<="
    case gt = ">"
    case ge = ">="
}

public enum MetaValue: Equatable, Sendable {
    case number(Double)
    case string(String)
}
