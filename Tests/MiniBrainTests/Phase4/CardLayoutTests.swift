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
                        tags: [ItemTag(name: "document", source: .ai)], fileURL: nil, snippet: nil,
                        customTypeName: nil, selected: false),
            GalleryCard(item: Item(type: .text, title: "Appreciate you reading this newsletter", content: long, createdAt: now),
                        tags: (1...6).map { ItemTag(name: "tag\($0)", source: .user) }, fileURL: nil,
                        snippet: "Appreciate you <mark>reading</mark> this newsletter,\nI am writing as I learn and explore",
                        customTypeName: nil, selected: false),
            GalleryCard(item: Item(type: .link, title: "substack.com", url: "https://substack.com/", createdAt: now),
                        tags: [ItemTag(name: "substack.com", source: .ai)], fileURL: nil, snippet: nil,
                        customTypeName: "Products", selected: true),
            GalleryCard(item: Item(type: .text, title: "", createdAt: now),
                        tags: [], fileURL: nil, snippet: nil, customTypeName: nil, selected: false),
            GalleryCard(item: Item(type: .pdf, title: "Invoice", content: "Total due", createdAt: now),
                        tags: [], fileURL: nil, snippet: nil, customTypeName: nil, selected: false,
                        showsRecognizedText: true),
        ]
        let heights = cards.map(height)
        #expect(Set(heights).count == 1, "card heights differ: \(heights)")
        #expect(heights[0] > 200) // thumbnail 170 + footer
    }
}
