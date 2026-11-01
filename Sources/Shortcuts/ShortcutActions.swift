import AppKit

struct ShortcutActionDefinition {
    let id: String
    let name: String
    let category: String
    let description: String
    var defaults: [String: String] = [:]
    var summary: ([String: String]) -> String = { _ in "" }
    var validate: ([String: String]) -> String? = { _ in nil }
    var editor: (([String: String], @escaping ([String: String]) -> Void) -> NSView)? = nil
    var requiredPermissions: Set<PermissionEntry> = []
    let execute: @MainActor (ShortcutActionInstance, ShortcutExecutionContext) async throws -> Void
}

final class ShortcutExecutionContext: @unchecked Sendable {
    let mouseButton: UInt16?
    let interactive: @MainActor (Bool) -> Void
    init(mouseButton: UInt16?, interactive: @escaping @MainActor (Bool) -> Void) { self.mouseButton = mouseButton; self.interactive = interactive }
    @MainActor func waitForMouseRelease() async throws {
        guard let button = mouseButton, let cgButton = CGMouseButton(rawValue: UInt32(button)) else { return }
        while CGEventSource.buttonState(.hidSystemState, button: cgButton) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
    }
}

struct ShortcutActionError: LocalizedError { let message: String; var errorDescription: String? { message } }

/// Future script providers register stable IDs such as script:<definition UUID>, with their own
/// execution-service closure and cooperative cancellation. No script configuration is copied here.
final class ShortcutActionRegistry {
    private(set) var definitions: [ShortcutActionDefinition] = []
    var onChange: (() -> Void)?
    var categories: [String] { Array(Set(definitions.map(\.category) + ["Scripts"])).sorted() }
    init() {
        register(ShortcutActionDefinition(id: "builtin.delay", name: "Delay", category: "Timing", description: "Pause before the next action (0.001–60 seconds).", defaults: ["seconds": "0.25"], summary: { "\($0["seconds"] ?? "0.25") seconds" }, validate: { parameters in
            guard let value = Double(parameters["seconds"] ?? "0.25"), value.isFinite, (0.001...60).contains(value) else { return "Delay must be between 0.001 and 60 seconds." }
            return nil
        }, editor: { parameters, changed in DelayActionEditor(parameters: parameters, changed: changed) }, execute: { instance, _ in
            guard let seconds = Double(instance.parameters["seconds"] ?? "0.25"), seconds.isFinite, (0.001...60).contains(seconds) else { throw ShortcutActionError(message: "Invalid Delay duration.") }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }))
        register(ShortcutActionDefinition(id: "builtin.screenshot.clipboard", name: "Capture Screen Selection to Clipboard", category: "Screen Capture", description: "Select a rectangle using the native macOS crosshairs. Copies directly to the clipboard.", requiredPermissions: [.screenRecording], execute: { _, context in
            try await context.waitForMouseRelease()
            try await ScreenshotSelectionGate.shared.acquire()
            context.interactive(true)
            defer { context.interactive(false); ScreenshotSelectionGate.shared.release() }
            let previous = NSPasteboard.general.changeCount
            let result = try await OwnedShortcutProcess(executable: "/usr/sbin/screencapture", arguments: ["-i", "-s", "-c"]).run()
            if result.status != 0 {
                if result.status == 1 && result.standardError.isEmpty { throw CancellationError() }
                throw ShortcutActionError(message: "Screen capture failed (exit \(result.status)). Check Screen Recording access in System Settings. \(result.standardError)")
            }
            try Task.checkCancellation()
            guard NSPasteboard.general.changeCount != previous, NSPasteboard.general.availableType(from: [.png, .tiff]) != nil else { throw CancellationError() }
        }))
    }
    func register(_ definition: ShortcutActionDefinition) {
        definitions.removeAll { $0.id == definition.id }; definitions.append(definition); onChange?()
    }
    func remove(id: String) { definitions.removeAll { $0.id == id }; onChange?() }
    func definition(_ id: String) -> ShortcutActionDefinition? { definitions.first { $0.id == id } }
    func unavailableReason(_ actions: [ShortcutActionInstance]) -> String? {
        for action in actions {
            guard let definition = definition(action.actionID) else { return "Unavailable action: \(action.actionID). Restore it or remove it from this shortcut." }
            if let error = definition.validate(action.parameters) { return error }
        }
        return nil
    }
}

@MainActor private final class ScreenshotSelectionGate {
    static let shared = ScreenshotSelectionGate()
    private var busy = false
    func acquire() async throws {
        while busy { try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation(); busy = true
    }
    func release() { busy = false }
}

/// Owns exactly one child process. Cancellation never targets another user's process group.
final class OwnedShortcutProcess: @unchecked Sendable {
    struct Result { let status: Int32; let standardError: String }
    private struct State { var process: Process?; var cancelled = false }
    private let state = Locked(State())
    private let executable: String
    private let arguments: [String]
    var isRunning: Bool { state.snapshot.process?.isRunning == true }
    init(executable: String, arguments: [String]) { self.executable = executable; self.arguments = arguments }
    func run() async throws -> Result {
        let result: Result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.withValue { state in
                    guard !state.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments; process.standardOutput = FileHandle.nullDevice
                    let pipe = Pipe(), errors = Locked(Data())
                    process.standardError = pipe
                    // Drain continuously, retaining only a bounded diagnostic prefix.
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty { handle.readabilityHandler = nil }
                        errors.withValue { buffer in buffer.append(data.prefix(max(0, 2048 - buffer.count))) }
                    }
                    process.terminationHandler = { process in
                        pipe.fileHandleForReading.readabilityHandler = nil
                        let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
                        errors.withValue { buffer in buffer.append(remainder.prefix(max(0, 2048 - buffer.count))) }
                        continuation.resume(returning: Result(status: process.terminationStatus, standardError: String(decoding: errors.snapshot, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    do { try process.run(); state.process = process }
                    catch { pipe.fileHandleForReading.readabilityHandler = nil; process.terminationHandler = nil; continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { [self] in
            let process = state.withValue { state -> Process? in state.cancelled = true; return state.process }
            if let process = process, process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                }
            }
        })
        try Task.checkCancellation()
        return result
    }
}

final class ShortcutActionRunner {
    private struct Running { let token: UUID; let task: Task<Void, Never> }
    private var running: [UUID: Running] = [:]
    let registry: ShortcutActionRegistry
    private let logger: FileLogger
    var onEscape: (() -> Void)?
    var onFailure: ((UUID, String) -> Void)?
    var onInteractiveChanged: ((Bool) -> Void)?
    private var interactiveCount = 0
    var isRunning: Bool { !running.isEmpty }
    var activeCount: Int { running.count }
    init(registry: ShortcutActionRegistry, logger: FileLogger) { self.registry = registry; self.logger = logger }
    @discardableResult func start(_ shortcut: ShortcutDefinition) -> Bool {
        guard running[shortcut.id] == nil, !shortcut.actions.isEmpty else { return false }
        let token = UUID()
        let context = ShortcutExecutionContext(mouseButton: shortcut.combination?.input == .mouse ? shortcut.combination?.code : nil) { [weak self] active in
            guard let self = self else { return }
            self.interactiveCount += active ? 1 : -1
            self.onInteractiveChanged?(self.interactiveCount > 0)
        }
        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { if self.running[shortcut.id]?.token == token { self.running.removeValue(forKey: shortcut.id) } }
            do {
                for action in shortcut.actions {
                    try Task.checkCancellation()
                    guard let definition = self.registry.definition(action.actionID) else { throw ShortcutActionError(message: "Action unavailable: \(action.actionID)") }
                    try await definition.execute(action, context)
                    try Task.checkCancellation()
                }
            } catch is CancellationError {
                self.logger.log("shortcuts", "cancelled", "Sequence \(shortcut.id) cancelled.")
            } catch {
                self.logger.log("shortcuts", "action.failure", "Sequence \(shortcut.id): \(error.localizedDescription)", severity: "WARN")
                self.onFailure?(shortcut.id, error.localizedDescription)
            }
        }
        running[shortcut.id] = Running(token: token, task: task)
        return true
    }
    func cancelAll(escape: Bool = false) {
        guard !running.isEmpty else { return }
        let newlyCancelled = running.values.contains { !$0.task.isCancelled }
        for sequence in running.values { sequence.task.cancel() }
        if escape && newlyCancelled { onEscape?() }
    }
    @MainActor func waitForCancellation() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ShortcutActionError(message: "Running actions did not finish cancelling. Permissions were not reset.") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func retainOnly(_ ids: Set<UUID>) { for (id, sequence) in running where !ids.contains(id) { sequence.task.cancel() } }
    func cancel(_ id: UUID) { running[id]?.task.cancel() }
}

final class DelayActionEditor: NSView {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let field = CommitField()
    private let error = UI.caption("")
    private var parameters: [String: String]
    private let changed: ([String: String]) -> Void
    init(parameters: [String: String], changed: @escaping ([String: String]) -> Void) {
        self.parameters = parameters; self.changed = changed
        super.init(frame: .zero)
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        field.setAccessibilityLabel("Delay in seconds"); slider.setAccessibilityLabel("Delay duration")
        error.textColor = .systemRed; error.isHidden = true
        UI.pin(UI.vertical([UI.horizontal([slider, field, UI.caption("seconds")]), error]), in: self)
        slider.target = self; slider.action = #selector(slid); slider.isContinuous = true
        field.commit = { [weak self] text in self?.commit(text) }
        let value = Double(parameters["seconds"] ?? "0.25") ?? 0.25
        update(value)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    private func update(_ value: Double) { slider.doubleValue = log(max(0.001, min(60, value)) / 0.001) / log(60_000); field.stringValue = String(value) }
    @objc private func slid() { commit(String(format: "%.3f", 0.001 * pow(60_000, slider.doubleValue))) }
    private func commit(_ text: String) {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, (0.001...60).contains(value) else { error.stringValue = "Enter 0.001 to 60 seconds."; error.isHidden = false; return }
        error.isHidden = true; update(value); parameters["seconds"] = String(value); changed(parameters)
    }
}
