import AppKit
import CoreGraphics
import CoreText
import Foundation
import MiniBrainCore

/// Developer tool. `mbtool make-fixtures <dir>` regenerates Tests/Fixtures.
@main
struct MBTool {
    static func main() throws {
        let args = CommandLine.arguments.dropFirst()
        guard let command = args.first else {
            print("usage: mbtool make-fixtures <dir>")
            exit(2)
        }
        switch command {
        case "make-fixtures":
            let dir = URL(fileURLWithPath: args.dropFirst().first ?? "Tests/Fixtures", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Fixtures.make(in: dir)
        default:
            print("unknown command \(command)")
            exit(2)
        }
    }
}

enum Fixtures {
    static func make(in dir: URL) throws {
        try pdf(pages: ["MiniBrain fixture invoice", "Second page walnut sideboard"], to: dir.appendingPathComponent("sample.pdf"))
        try pdf(pages: [""], to: dir.appendingPathComponent("empty.pdf"))
        try pdf(pages: ["Top secret pancake recipe"], to: dir.appendingPathComponent("encrypted.pdf"), password: "hunter2")
        try png(width: 900, height: 260, to: dir.appendingPathComponent("text.png")) { ctx in
            fill(ctx, .white, CGRect(x: 0, y: 0, width: 900, height: 260))
            drawText("HELLO MINIBRAIN 2024", in: ctx, at: CGPoint(x: 40, y: 100), size: 64)
        }
        try png(width: 200, height: 200, to: dir.appendingPathComponent("blank.png")) { ctx in
            fill(ctx, .white, CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        try png(width: 64, height: 64, to: dir.appendingPathComponent("red.png")) { ctx in
            fill(ctx, CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try png(width: 100, height: 100, to: dir.appendingPathComponent("two-color.png")) { ctx in
            fill(ctx, CGColor(srgbRed: 0.05, green: 0.25, blue: 0.95, alpha: 1), CGRect(x: 0, y: 0, width: 50, height: 100))
            fill(ctx, CGColor(srgbRed: 1, green: 0.85, blue: 0.05, alpha: 1), CGRect(x: 50, y: 0, width: 50, height: 100))
        }
        try """
            Version:0.9
            StartHTML:0000000105
            EndHTML:0000000300
            SourceURL:https://www.example.com/articles/walnut-sideboards
            <html><body><!--StartFragment--><p>Mid-century <b>walnut</b> sideboards are back.</p><!--EndFragment--></body></html>
            """.write(to: dir.appendingPathComponent("snippet-cfhtml.html"), atomically: true, encoding: .utf8)
        try """
            <meta charset='utf-8'><link rel="canonical" href="https://blog.example.org/post/42"><p>Swift <i>actors</i> &amp; isolation</p>
            """.write(to: dir.appendingPathComponent("snippet-canonical.html"), atomically: true, encoding: .utf8)
        try """
            <meta charset='utf-8'><span style="color: rgb(0,0,0)">Just a quote with no source&nbsp;at all.</span>
            """.write(to: dir.appendingPathComponent("snippet-nosource.html"), atomically: true, encoding: .utf8)
        try v1Database(at: dir.appendingPathComponent("v1.sqlite"))
        print("fixtures written to \(dir.path)")
    }

    static func fill(_ ctx: CGContext, _ color: CGColor, _ rect: CGRect) {
        ctx.setFillColor(color)
        ctx.fill(rect)
    }

    static func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    static func png(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    static func pdf(pages: [String], to url: URL, password: String? = nil) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [kCGPDFContextTitle: url.deletingPathExtension().lastPathComponent]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
        for text in pages {
            ctx.beginPDFPage(nil)
            if !text.isEmpty { drawText(text, in: ctx, at: CGPoint(x: 72, y: 700), size: 24) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// A schema-v1 database with a few items, tags and queue rows, used to
    /// test v1 → v2 migration and opening an existing library.
    static func v1Database(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        // DatabaseQueue (rollback journal) so the fixture is a single file.
        let db = try AppDatabase.openSingleFile(at: url, upTo: AppDatabase.schemaV1)
        let created = Date(timeIntervalSince1970: 1_717_000_000)
        let repo = ItemRepository(database: db, clock: FixedClock(now: created))
        let items = [
            Item(id: "fixture-text", type: .text, title: "Grocery list", content: "oat milk, eggs, coffee beans", createdAt: created),
            Item(id: "fixture-link", type: .link, title: "GRDB docs", url: "https://github.com/groue/GRDB.swift",
                 meta: ["host": "github.com"], createdAt: created.addingTimeInterval(60)),
            Item(id: "fixture-image", type: .image, title: "Red chair", blobHash: String(repeating: "a", count: 64),
                 meta: ["colors": ["red"], "price": 299], createdAt: created.addingTimeInterval(120)),
            Item(id: "fixture-trashed", type: .text, title: "Old idea", createdAt: created.addingTimeInterval(180),
                 trashedAt: created.addingTimeInterval(240)),
        ]
        for item in items { try repo.insert(item) }
        try repo.attachTag("groceries", to: "fixture-text")
        try repo.attachTag("dev", to: "fixture-link")
        try repo.attachTag("wishlist", to: "fixture-image", source: .ai)
        try db.writer.write { conn in
            try EnrichmentQueue.enqueue(itemID: "fixture-image", kind: .colors, now: created, in: conn)
        }
    }
}

struct FixedClock: MiniBrainCore.Clock {
    let now: Date
    func sleep(for seconds: TimeInterval) async throws {}
}
