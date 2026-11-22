import AppKit
import MiniBrainCore
import Observation

/// Capture entry point used by the UI (wraps CaptureService off the main actor).
public protocol Capturing: Sendable {
    func save(_ payload: CapturePayload, customTypeID: String?) async throws -> Item
}

extension Capturing {
    public func save(_ payload: CapturePayload) async throws -> Item { try await save(payload, customTypeID: nil) }
}

extension CaptureService: Capturing {
    public func save(_ payload: CapturePayload, customTypeID: String?) async throws -> Item {
        let service = self
        return try await Task.detached(priority: .userInitiated) {
            try service.capture(payload, customTypeID: customTypeID)
        }.value
    }
}

/// idle → hovering → saving → saved / error → idle
///
/// ⇧-drop: hovering → choosingType → saving → editingFields → saved.
@MainActor
@Observable
public final class DropBoxViewModel {
    public enum State: Equatable {
        case idle
        case hovering
        case saving
        case saved(title: String)
        case error(String)
        /// ⇧-drop: waiting for the user to pick a custom type.
        case choosingType([CustomType])
        /// Saved into a custom type; user fills its fields.
        case editingFields(item: Item, type: CustomType)
    }

    public private(set) var state: State = .idle
    /// Custom types shown as drop zones under the main target.
    public private(set) var types: [CustomType] = []
    /// Type zone currently under the drag (nil = main zone or none).
    public private(set) var hoveredTypeID: String?
    @ObservationIgnored private var targetedZones: Set<String> = []
    /// "Auto-tag every drop" (mirrors Settings; changed with ←/→/Return).
    public var autoTag = true
    @ObservationIgnored public var onAutoTagChange: ((Bool) -> Void)?

    public func setAutoTag(_ on: Bool) {
        guard on != autoTag else { return }
        autoTag = on
        onAutoTagChange?(on)
    }

    /// ⇧ was held at some point while hovering the main zone.
    @ObservationIgnored public var shiftSeenDuringHover = false
    @ObservationIgnored let capturer: any Capturing
    @ObservationIgnored let customTypes: CustomTypeRepository?
    @ObservationIgnored let clock: any MiniBrainCore.Clock
    /// How long `saved`/`error` stays visible before returning to idle.
    @ObservationIgnored public var resetDelay: TimeInterval = 1.5
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPayload: CapturePayload?
    @ObservationIgnored public var onSaved: ((Item) -> Void)?
    @ObservationIgnored public var onOpenSettings: (() -> Void)?

    public init(capturer: any Capturing, customTypes: CustomTypeRepository? = nil,
                clock: any MiniBrainCore.Clock = SystemClock()) {
        self.capturer = capturer
        self.customTypes = customTypes
        self.clock = clock
    }

    /// True while the user is choosing a type or filling fields.
    public var isAwaitingInput: Bool {
        switch state {
        case .choosingType, .editingFields: true
        default: false
        }
    }

    /// Reloads the type zones (call when the box is shown).
    public func refreshTypes() {
        types = (try? customTypes?.all()) ?? []
    }

    public static let mainZone = "main"

    public func dragEntered(zone: String = DropBoxViewModel.mainZone) {
        if targetedZones.isEmpty { shiftSeenDuringHover = false }
        targetedZones.insert(zone)
        hoveredTypeID = zone == Self.mainZone ? hoveredTypeID : zone
        guard state != .saving, !isAwaitingInput else { return }
        resetTask?.cancel()
        state = .hovering
    }

    public func dragExited(zone: String = DropBoxViewModel.mainZone) {
        targetedZones.remove(zone)
        if hoveredTypeID == zone { hoveredTypeID = nil }
        if targetedZones.isEmpty, state == .hovering { state = .idle }
    }

    /// Drop on a type zone: save straight into that type, then show its fields.
    @discardableResult
    public func drop(_ providers: [NSItemProvider], into type: CustomType) async -> Bool {
        targetedZones.removeAll()
        hoveredTypeID = nil
        state = .saving
        do {
            let payload = try await ItemProviderMapper.payload(from: providers)
            pendingPayload = payload
            await choose(type)
            if case .error = state { return false }
            return true
        } catch {
            finish(.error(Self.message(for: error)))
            return false
        }
    }

    /// Drop path: providers → payload → capture. With `chooseType` (⇧ held),
    /// asks which custom type to save into first.
    @discardableResult
    public func drop(_ providers: [NSItemProvider], chooseType: Bool = false) async -> Bool {
        targetedZones.removeAll()
        hoveredTypeID = nil
        state = .saving
        do {
            let payload = try await ItemProviderMapper.payload(from: providers)
            if chooseType { return try askForType(payload) }
            return await save(payload)
        } catch {
            finish(.error(Self.message(for: error)))
            return false
        }
    }

    /// Paste path (⌘V in the drop box): same capture pipeline.
    @discardableResult
    public func paste(_ pasteboard: any PasteboardReading, chooseType: Bool = false) async -> Bool {
        state = .saving
        do {
            let payload = try PasteboardPayloadMapper.payload(from: pasteboard)
            if chooseType { return try askForType(payload) }
            return await save(payload)
        } catch {
            finish(.error(Self.message(for: error)))
            return false
        }
    }

    private func askForType(_ payload: CapturePayload) throws -> Bool {
        _ = try TypeDetector.detect(payload) // reject unsupported content before asking
        resetTask?.cancel()
        pendingPayload = payload
        refreshTypes()
        state = .choosingType(types)
        return true
    }

    /// Saves the pending ⇧-drop into `type` (nil = no custom type).
    public func choose(_ type: CustomType?) async {
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        state = .saving
        do {
            let item = try await capturer.save(payload, customTypeID: type?.id)
            onSaved?(item)
            if let type {
                // Always ask for a name when filing into a custom type.
                state = .editingFields(item: item, type: type)
            } else {
                finish(.saved(title: type.map { "to \($0.name)" } ?? item.title))
            }
        } catch {
            finish(.error(Self.message(for: error)))
        }
    }

    public func cancelChoice() {
        pendingPayload = nil
        state = .idle
    }

    /// Saves the name + field form shown after dropping into a type.
    public func saveFields(_ values: [String: String], title: String? = nil) {
        guard case .editingFields(let item, let type) = state else { return }
        do {
            if let updated = try customTypes?.setFieldValues(values, title: title, for: item.id) { onSaved?(updated) }
            finish(.saved(title: "to \(type.name)"))
        } catch {
            finish(.error(Self.message(for: error)))
        }
    }

    public func skipFields() {
        guard case .editingFields(_, let type) = state else { return }
        finish(.saved(title: "to \(type.name)"))
    }

    public func openSettings() {
        cancelChoice()
        onOpenSettings?()
    }

    private func save(_ payload: CapturePayload) async -> Bool {
        do {
            let item = try await capturer.save(payload)
            finish(.saved(title: item.title))
            onSaved?(item)
            return true
        } catch {
            finish(.error(Self.message(for: error)))
            return false
        }
    }

    private func finish(_ newState: State) {
        state = newState
        resetTask?.cancel()
        let delay = resetDelay
        resetTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if case .saved = self.state { self.state = .idle }
            if case .error = self.state { self.state = .idle }
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case MiniBrainError.emptyPayload: "Nothing to save"
        case MiniBrainError.unsupportedPayload: "Unsupported content"
        default: "Couldn't save: \(error.localizedDescription)"
        }
    }
}
