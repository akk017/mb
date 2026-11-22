import AppKit
import Foundation
import Testing
@testable import MiniBrainCore
@testable import MiniBrainUI

@Suite @MainActor struct TypeZoneTests {
    func make() throws -> (TestEnv, CustomTypeRepository, DropBoxViewModel) {
        let env = try TestEnv()
        let repo = CustomTypeRepository(database: env.db, clock: env.clock)
        let capture = CaptureService(database: env.db, blobs: env.blobs, clock: env.clock)
        return (env, repo, DropBoxViewModel(capturer: capture, customTypes: repo, clock: FakeClock()))
    }

    @Test func zonesListCustomTypes() throws {
        let (_, repo, vm) = try make()
        #expect(vm.types.isEmpty)
        let products = try productsType(repo)
        let gifts = try repo.create(name: "Gifts")
        vm.refreshTypes()
        #expect(vm.types == [gifts, products])
    }

    @Test func dropOnTypeZoneSavesIntoTypeAndOpensFields() async throws {
        let (env, repo, vm) = try make()
        let products = try productsType(repo)
        vm.refreshTypes()
        let provider = NSItemProvider(object: URL(string: "https://shop.example.com/lamp")! as NSURL)
        #expect(await vm.drop([provider], into: products))
        guard case .editingFields(let item, let type) = vm.state else {
            Issue.record("expected field form, got \(vm.state)"); return
        }
        #expect(type == products)
        #expect(try env.repo.fetch(item.id)?.customTypeID == products.id)
        #expect(item.fieldValues[products.fields[2].id] == "https://shop.example.com/lamp")
        vm.saveFields(item.fieldValues)
        #expect(vm.state == .saved(title: "to Products"))
    }

    @Test func dropOnFieldlessTypeAsksForName() async throws {
        let (env, repo, vm) = try make()
        let inbox = try repo.create(name: "Inbox")
        #expect(await vm.drop([NSItemProvider(object: "note" as NSString)], into: inbox))
        guard case .editingFields(_, let type) = vm.state else {
            Issue.record("expected name form, got \(vm.state)"); return
        }
        #expect(type.id == inbox.id)
        #expect(try env.repo.fetchAll().first?.customTypeID == inbox.id)
        vm.saveFields([:], title: "Renamed")
        #expect(vm.state == .saved(title: "to Inbox"))
        #expect(try env.repo.fetchAll().first?.title == "Renamed")
    }

    @Test func badPayloadOnTypeZoneShowsError() async throws {
        let (env, repo, vm) = try make()
        let inbox = try repo.create(name: "Inbox")
        let bad = NSItemProvider(item: Data([1]) as NSData, typeIdentifier: "com.example.unknown")
        #expect(await vm.drop([bad], into: inbox) == false)
        #expect(vm.state == .error("Unsupported content"))
        #expect(try env.repo.count() == 0)
    }

    @Test func hoverTracksWhichZone() throws {
        let (_, repo, vm) = try make()
        let products = try productsType(repo)
        vm.dragEntered()
        #expect(vm.state == .hovering)
        #expect(vm.hoveredTypeID == nil)
        // Moving from the main zone onto a type zone.
        vm.dragEntered(zone: products.id)
        vm.dragExited()
        #expect(vm.state == .hovering)
        #expect(vm.hoveredTypeID == products.id)
        vm.dragExited(zone: products.id)
        #expect(vm.state == .idle)
        #expect(vm.hoveredTypeID == nil)
    }

    @Test func shiftFlagResetsPerDrag() throws {
        let (_, _, vm) = try make()
        vm.dragEntered()
        vm.shiftSeenDuringHover = true
        vm.dragExited()
        vm.dragEntered() // a new drag starts clean
        #expect(!vm.shiftSeenDuringHover)
    }
}
