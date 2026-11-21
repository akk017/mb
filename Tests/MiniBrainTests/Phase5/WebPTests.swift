import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MiniBrainCore
@testable import MiniBrainUI

/// Photo-like test image (noisy gradient) encoded with ImageIO.
func makeImage(width: Int, height: Int, type: UTType = .png, orientation: Int? = nil, frames: Int = 1) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var rng = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: height, by: 4) {
        for x in stride(from: 0, to: width, by: 4) {
            let n = Double.random(in: 0...0.15, using: &rng)
            ctx.setFillColor(CGColor(srgbRed: Double(x) / Double(width), green: Double(y) / Double(height), blue: 0.5 + n, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
    }
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
    var props: [CFString: Any] = [:]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    if frames > 1 { props[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: 0.1] }
    for _ in 0..<frames { CGImageDestinationAddImage(dest, image, props as CFDictionary) }
    CGImageDestinationFinalize(dest)
    return data as Data
}

func pixelSize(_ data: Data) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
}

@Suite struct WebPEncoderTests {
    @Test func encodesDecodableWebP() throws {
        let png = makeImage(width: 640, height: 480)
        let webp = try #require(ImageOptimizer.webp(from: png))
        #expect(webp.prefix(4) == Data("RIFF".utf8))
        #expect(DataSniffer.imageExtension(webp) == "webp")
        #expect(pixelSize(webp)! == (640, 480))
        #expect(webp.count < png.count)
    }

    @Test func jpegShrinksAndKeepsOrientation() throws {
        // 200×100 stored with EXIF "rotate 90° CW" → displays as 100×200.
        let jpeg = makeImage(width: 200, height: 100, type: .jpeg, orientation: 6)
        if let webp = ImageOptimizer.webp(from: jpeg, quality: 60) {
            #expect(pixelSize(webp)! == (100, 200)) // orientation baked in
        }
    }

    @Test func skipsWebPAnimatedGifAndGarbage() throws {
        let webp = try #require(ImageOptimizer.webp(from: makeImage(width: 300, height: 200)))
        #expect(ImageOptimizer.webp(from: webp) == nil)                       // already WebP
        #expect(ImageOptimizer.webp(from: makeImage(width: 120, height: 80, type: .gif, frames: 3)) == nil) // animation kept
        #expect(ImageOptimizer.webp(from: Data("not an image".utf8)) == nil)
    }

    @Test func ocrStillReadsWebPText() throws {
        let webp = try #require(ImageOptimizer.webp(from: try Fixtures.data("text.png")))
        let words = try OCRRecognizer.recognize(webp).joined(separator: " ").uppercased()
        #expect(words.contains("MINIBRAIN"))
    }
}

@Suite struct ImageOptimizeJobTests {
    func optimize(_ env: TestEnv, _ itemID: String, enabled: Bool = true) async throws {
        try env.write { try EnrichmentQueue.enqueue(itemID: itemID, kind: .optimizeImage, now: env.clock.now, in: $0) }
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock,
                                      processors: [ImageOptimizeProcessor(isEnabled: { enabled })])
        #expect(await worker.runPending() == 1)
    }

    @Test func imageIsReplacedByWebPAndOldFileRemoved() async throws {
        let env = try TestEnv()
        let png = makeImage(width: 800, height: 600)
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, enabledKinds: [])
        let item = try capture.capture(.imageData(png))
        let oldHash = try #require(item.blobHash)
        try await optimize(env, item.id)

        let saved = try #require(try env.repo.fetch(item.id))
        let newHash = try #require(saved.blobHash)
        #expect(newHash != oldHash)
        #expect(env.blobs.url(for: newHash)?.pathExtension == "webp")
        #expect(!env.blobs.exists(oldHash))
        #expect(saved.meta["format"] == "webp")
        #expect(saved.meta["original_byte_size"] == .number(Double(png.count)))
        #expect(saved.meta[ImageOptimizeProcessor.optimizedKey] == true)

        try await optimize(env, item.id) // idempotent
        #expect(try env.repo.fetch(item.id)?.blobHash == newHash)
    }

    @Test func sharedOriginalKeptUntilLastItemConverted() async throws {
        let env = try TestEnv()
        let hash = try env.blobs.store(makeImage(width: 500, height: 400), fileExtension: "png").hash
        let a = try env.makeItem(.image, blobHash: hash), b = try env.makeItem(.image, blobHash: hash)
        try await optimize(env, a.id)
        #expect(env.blobs.exists(hash)) // b still uses it
        try await optimize(env, b.id)
        #expect(!env.blobs.exists(hash))
        #expect(try env.repo.fetch(a.id)?.blobHash == env.repo.fetch(b.id)?.blobHash) // same WebP, stored once
    }

    @Test func disabledLeavesImagesAlone() async throws {
        let env = try TestEnv()
        let hash = try env.blobs.store(makeImage(width: 400, height: 300), fileExtension: "png").hash
        let item = try env.makeItem(.image, blobHash: hash)
        try await optimize(env, item.id, enabled: false)
        #expect(try env.repo.fetch(item.id)?.blobHash == hash)
    }

    @Test func existingLinkPreviewConverted() async throws {
        let env = try TestEnv()
        let hash = try env.blobs.store(makeImage(width: 600, height: 315), fileExtension: "png").hash
        let link = try env.makeItem(.link, title: "l", url: "https://a.com", meta: [LinkPreviewProcessor.previewBlobKey: .string(hash)])
        try await optimize(env, link.id)
        let newHash = try #require(try env.repo.fetch(link.id)?.meta[LinkPreviewProcessor.previewBlobKey]?.stringValue)
        #expect(newHash != hash)
        #expect(DataSniffer.imageExtension(try env.blobs.read(newHash)) == "webp")
        #expect(!env.blobs.exists(hash))
    }

    @Test func imagesQueueOptimizationLast() {
        #expect(EnrichmentKind.kinds(for: .image).last == .optimizeImage)
    }
}

@Suite @MainActor struct WebPCopyTests {
    @Test func copyingWebPGivesPNGAndTIFF() throws {
        let env = try TestEnv()
        let webp = try #require(ImageOptimizer.webp(from: makeImage(width: 300, height: 200)))
        let hash = try env.blobs.store(webp, fileExtension: "webp").hash
        let item = try env.makeItem(.image, blobHash: hash)
        let pb = FakePasteboardWriter()
        let actions = ItemActions(workspace: FakeWorkspace(), pasteboard: pb, blobs: env.blobs, repository: env.repo)
        #expect(try actions.copy(item))
        #expect(pb.datas[.png].flatMap(DataSniffer.imageExtension) == "png")
        #expect(pb.datas[.tiff] != nil)
    }
}
