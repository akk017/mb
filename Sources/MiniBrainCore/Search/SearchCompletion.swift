import Foundation

/// Autocomplete for the search syntax: completes the word being typed
/// (the text after the last space) — filter keywords, tags, types, colors.
public enum SearchCompletion {
    public enum Kind: String, Sendable { case keyword, tag, type, color }

    public struct Suggestion: Equatable, Sendable, Identifiable {
        /// Shown in the list (e.g. the tag name).
        public var title: String
        /// What replaces the word being typed (e.g. `tag:"blue sky" `).
        public var replacement: String
        public var kind: Kind
        public var id: String { "\(kind.rawValue):\(replacement)" }
    }

    public struct Context: Sendable {
        public var tags: [String]
        public var customTypes: [String]
        public var colors: [String]

        public init(tags: [String], customTypes: [String], colors: [String] = SearchCompletion.colors) {
            self.tags = tags
            self.customTypes = customTypes
            self.colors = colors
        }
    }

    public static let colors = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "brown", "black", "white", "gray"]
    public static let builtInTypes = ["image", "link", "text", "pdf"]
    static let keywords = ["tag:", "type:", "color:", "after:", "before:", "meta."]
    public static let maxSuggestions = 8

    /// Start of the word being typed (after the last space outside quotes).
    static func currentWordStart(in text: String) -> String.Index {
        var start = text.startIndex
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" { inQuotes.toggle() }
            if c.isWhitespace && !inQuotes { start = text.index(after: i) }
            i = text.index(after: i)
        }
        return start
    }

    public static func suggestions(for text: String, context: Context) -> [Suggestion] {
        let word = String(text[currentWordStart(in: text)...])
        guard !word.isEmpty else { return [] }

        if let colon = word.firstIndex(of: ":") {
            let key = word[..<colon].lowercased()
            var value = String(word[word.index(after: colon)...])
            if value.hasPrefix("\"") { value.removeFirst() }
            if value.hasSuffix("\""), value.count > 1 { return [] } // already closed
            let (kind, candidates): (Kind, [String]) = switch key {
            case "tag": (.tag, context.tags)
            case "type": (.type, context.customTypes + builtInTypes)
            case "color": (.color, context.colors)
            default: (.keyword, [])
            }
            guard kind != .keyword else { return [] }
            return rank(candidates, matching: value).compactMap { name in
                // Nothing to complete if it's already exactly typed.
                guard name.caseInsensitiveCompare(value) != .orderedSame else { return nil }
                return Suggestion(title: name, replacement: "\(key):\(quoted(name)) ", kind: kind)
            }
            .prefix(maxSuggestions).map { $0 }
        }

        // Filter keywords ("ta" → "tag:").
        let lower = word.lowercased()
        return keywords
            .filter { $0.hasPrefix(lower) && $0 != lower }
            .map { Suggestion(title: $0, replacement: $0, kind: .keyword) }
    }

    /// Prefix matches first (alphabetical), then other substring matches.
    static func rank(_ candidates: [String], matching value: String) -> [String] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.lowercased()).inserted }
        guard !value.isEmpty else { return unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
        let v = value.lowercased()
        let prefix = unique.filter { $0.lowercased().hasPrefix(v) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let contains = unique.filter { !$0.lowercased().hasPrefix(v) && $0.lowercased().contains(v) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return prefix + contains
    }

    static func quoted(_ name: String) -> String {
        name.contains(where: \.isWhitespace) ? "\"\(name)\"" : name
    }

    /// Text after accepting `suggestion` (replaces the word being typed).
    public static func apply(_ suggestion: Suggestion, to text: String) -> String {
        String(text[..<currentWordStart(in: text)]) + suggestion.replacement
    }
}
