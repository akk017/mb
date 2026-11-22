import AppKit
import SwiftUI
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite @MainActor struct CardLayoutTests {
    func height(_ card: GalleryCard) -> CGFloat {
        let host = NSHostingView(rootView: card.frame(width: 280))
        return host.fittingSize.height
    }

    @Test func allCardsHaveTheSameHeight() {
        let now = Date()
        let long = String(repeating: "Appreciate you reading this newsletter, I am writing as I learn. ", count: 6)
        let cards: [GalleryCard] = [
            GalleryCard(item: Item(type: .image, title: "Image", content: long, createdAt: now),
                        tags: [ItemTag(name: "document", source: .ai)], thumbnail: nil, snippet: nil,
                        customTypeName: nil, selected: false),
            GalleryCard(item: Item(type: .text, title: "Appreciate you reading this newsletter", content: long, createdAt: now),
                        tags: (1...6).map { ItemTag(name: "tag\($0)", source: .user) }, thumbnail: nil,
                        snippet: "Appreciate you <mark>reading</mark> this newsletter,\nI am writing as I learn and explore",
                        customTypeName: nil, selected: false),
            GalleryCard(item: Item(type: .link, title: "substack.com", url: "https://substack.com/", createdAt: now),
                        tags: [ItemTag(name: "substack.com", source: .ai)], thumbnail: nil, snippet: nil,
                        customTypeName: "Products", selected: true),
            GalleryCard(item: Item(type: .text, title: "", createdAt: now),
                        tags: [], thumbnail: nil, snippet: nil, customTypeName: nil, selected: false),
            GalleryCard(item: Item(type: .pdf, title: "Invoice", content: "Total due", createdAt: now),
                        tags: [], thumbnail: nil, snippet: nil, customTypeName: nil, selected: false,
                        showsRecognizedText: true),
        ]
        let heights = cards.map(height)
        #expect(Set(heights).count == 1, "card heights differ: \(heights)")
        #expect(heights[0] > 200) // thumbnail 170 + footer
    }
}

@Suite struct CardInfoLineTests {
    let now = Date()

    @Test func pdfNeverShowsExtractedText() {
        let pdf = Item(type: .pdf, title: "GATE 2027", content: "Gate Prep Akash K 28 Jun 2026 1 Weightage", createdAt: now)
        #expect(GalleryCard.infoLine(for: pdf, snippet: nil, showsRecognizedText: true) == .blank)
        #expect(GalleryCard.infoLine(for: pdf, snippet: "Gate <mark>Prep</mark>", showsRecognizedText: true) == .blank)
    }

    @Test func imageOCRTextOnlyWhenEnabled() {
        let image = Item(type: .image, title: "Shot", content: "public init()", createdAt: now)
        #expect(GalleryCard.infoLine(for: image, snippet: "<mark>public</mark> init", showsRecognizedText: false) == .blank)
        #expect(GalleryCard.infoLine(for: image, snippet: "<mark>public</mark> init", showsRecognizedText: true)
                == .snippet("<mark>public</mark> init"))
    }

    @Test func urlWinsAndTextNotesKeepSnippets() {
        let link = Item(type: .link, title: "k", content: "page text", url: "https://karpenter.sh/", createdAt: now)
        #expect(GalleryCard.infoLine(for: link, snippet: "page", showsRecognizedText: true) == .url("https://karpenter.sh/"))
        let note = Item(type: .text, title: "n", content: "remember the walnut", createdAt: now)
        #expect(GalleryCard.infoLine(for: note, snippet: "<mark>walnut</mark>", showsRecognizedText: false) == .snippet("<mark>walnut</mark>"))
        #expect(GalleryCard.infoLine(for: note, snippet: nil, showsRecognizedText: false) == .blank)
    }
}
