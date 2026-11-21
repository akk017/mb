import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _on: Bool
    init(_ on: Bool) { _on = on }
    var on: Bool { get { lock.withLock { _on } } set { lock.withLock { _on = newValue } } }
}

@Suite struct OCRSettingsTests {
    @Test func disabledOCRSkipsNewImages() throws {
        let env = try TestEnv()
        let ocr = Flag(false)
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock,
                                     isKindEnabled: { $0 != .ocr || ocr.on })
        let off = try capture.capture(.imageData(try Fixtures.data("text.png")))
        #expect(!(try jobs(env, off.id).map(\.kind).contains(.ocr)))
        #expect(try jobs(env, off.id).map(\.kind).contains(.colors)) // other jobs still run
        ocr.on = true
        let on = try capture.capture(.imageData(try Fixtures.data("red.png")))
        #expect(try jobs(env, on.id).map(\.kind).contains(.ocr))
    }

    @Test func queuedOCRJobSkippedWhenTurnedOff() async throws {
        let env = try TestEnv()
        let ocr = Flag(true)
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock, enabledKinds: [.ocr])
        let item = try capture.capture(.imageData(try Fixtures.data("text.png")))
        ocr.on = false // user turns OCR off before the job runs
        let worker = EnrichmentWorker(database: env.db, blobs: env.blobs, clock: env.clock,
                                      processors: [OCRProcessor(isEnabled: { ocr.on })])
        #expect(await worker.runPending() == 1)
        #expect(try jobs(env, item.id).first?.status == .done)
        #expect(try env.repo.fetch(item.id)?.content == "")
    }

    @Test func clearRecognizedTextRemovesOCRFromImagesOnly() async throws {
        let env = try TestEnv()
        let image = try await runProcessor(OCRProcessor(), payload: .imageData(try Fixtures.data("text.png")), env: env)
        #expect(image.content.uppercased().contains("MINIBRAIN"))
        let note = try env.makeItem(.text, title: "note", content: "minibrain notes stay")
        let search = SearchService(database: env.db)
        #expect(Set(try search.search("minibrain").map(\.id)) == [image.id, note.id])

        #expect(try env.repo.clearRecognizedText() == 1)
        let cleared = try #require(try env.repo.fetch(image.id))
        #expect(cleared.content == "")
        #expect(cleared.meta["has_text"] == nil)
        #expect(try search.search("minibrain").map(\.id) == [note.id])
        #expect(try env.repo.clearRecognizedText() == 0)
    }
}

@Suite @MainActor struct OCRPreferenceTests {
    @Test func defaultsAndPersistence() {
        let d = makeDefaults()
        let p = AppPreferences(defaults: d)
        #expect(p.ocrEnabled)
        #expect(!p.showRecognizedText)
        #expect(AppPreferences.isOCREnabled(defaults: d))
        p.ocrEnabled = false
        p.showRecognizedText = true
        let reloaded = AppPreferences(defaults: d)
        #expect(!reloaded.ocrEnabled)
        #expect(reloaded.showRecognizedText)
        #expect(!AppPreferences.isOCREnabled(defaults: d))
    }

    @Test func libraryHidesOCRByDefault() throws {
        let env = try TestEnv()
        let vm = LibraryViewModel(search: SearchService(database: env.db), repository: env.repo, clock: env.clock)
        #expect(!vm.showsRecognizedText)
    }
}
