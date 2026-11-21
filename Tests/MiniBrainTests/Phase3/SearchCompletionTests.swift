import Testing
@testable import MiniBrainCore

@Suite struct SearchCompletionTests {
    let ctx = SearchCompletion.Context(
        tags: ["cloudy", "Clothing", "blue sky", "uncle", "backend"], customTypes: ["Products", "Gift Ideas"])

    func titles(_ text: String) -> [String] { SearchCompletion.suggestions(for: text, context: ctx).map(\.title) }

    @Test func tagPrefixThenContains() {
        #expect(titles("tag:cl") == ["Clothing", "cloudy", "uncle"])
        #expect(titles("walnut tag:CL") == ["Clothing", "cloudy", "uncle"])
        #expect(titles("tag:zz").isEmpty)
    }

    @Test func emptyValueListsAll() {
        #expect(titles("tag:") == ["backend", "blue sky", "Clothing", "cloudy", "uncle"])
        #expect(titles("color:").count == min(SearchCompletion.colors.count, SearchCompletion.maxSuggestions))
    }

    @Test func typesIncludeCustomAndBuiltIn() {
        #expect(titles("type:") == ["Gift Ideas", "image", "link", "pdf", "Products", "text"])
        #expect(titles("type:p") == ["pdf", "Products"])
    }

    @Test func keywordsComplete() {
        #expect(titles("ta") == ["tag:"])
        #expect(titles("chair co") == ["color:"])
        #expect(titles("t") == ["tag:", "type:"])
        #expect(titles("tag:").isEmpty == false)
        #expect(titles("walnut").isEmpty)
        #expect(titles("").isEmpty)
        #expect(titles("chair ").isEmpty) // nothing typed yet for the next word
    }

    @Test func applyReplacesCurrentWordAndQuotes() {
        let blue = SearchCompletion.suggestions(for: "lamp tag:blu", context: ctx).first!
        #expect(blue.replacement == "tag:\"blue sky\" ")
        #expect(SearchCompletion.apply(blue, to: "lamp tag:blu") == "lamp tag:\"blue sky\" ")
        let kw = SearchCompletion.suggestions(for: "lamp ty", context: ctx).first!
        #expect(SearchCompletion.apply(kw, to: "lamp ty") == "lamp type:")
        let gift = SearchCompletion.suggestions(for: "type:gi", context: ctx).first!
        #expect(SearchCompletion.apply(gift, to: "type:gi") == "type:\"Gift Ideas\" ")
    }

    @Test func quotedValueInProgress() {
        #expect(titles("tag:\"blue s") == ["blue sky"])
        #expect(titles("tag:\"blue sky\"").isEmpty) // closed quote = done
    }

    @Test func exactMatchNotSuggested() {
        #expect(titles("tag:cloudy").isEmpty)
        #expect(titles("type:image").isEmpty)
    }

    @Test func completedResultParses() throws {
        let s = SearchCompletion.suggestions(for: "tag:blu", context: ctx).first!
        let q = try QueryParser().parse(SearchCompletion.apply(s, to: "tag:blu"))
        #expect(q.filters == [.tag("blue sky")])
    }
}
