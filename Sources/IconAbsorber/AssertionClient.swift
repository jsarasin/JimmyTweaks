import AppKit
import Darwin

/// The UI process never loads private frameworks. Pipe EOF on a parent crash
/// makes the assertion holder exit; its own death also drops the system assertion.
final class IconAssertionClient {
    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var pending: [Int: (Result<Bool, Error>) -> Void] = [:]
    private var timeouts: [Int: DispatchWorkItem] = [:]
    private var launchToken = UUID()
    private(set) var held = false
    private var ready = false
    private var queued: ([String], (Result<Bool, Error>) -> Void)?
    #if TESTING
    var executableForTesting: URL?
    var processIDForTesting: pid_t? { process?.isRunning == true ? process?.processIdentifier : nil }
    #endif
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
    func apply(hidden: [String], completion: @escaping (Result<Bool, Error>) -> Void) {
        if !ready {
            queued?.1(.failure(Failure.message("Superseded")))
            queued = (hidden, completion)
            if process == nil { start() }
            return
        }
        sequence += 1; let id = sequence
        // Requests supersede old state. Their callers gate completions by generation.
        let old = pending; pending = [:]
        timeouts.values.forEach { $0.cancel() }; timeouts = [:]
        old.values.forEach { $0(.failure(Failure.message("Superseded"))) }
        pending[id] = completion
        let timeout = DispatchWorkItem { [weak self] in self?.fail("The visibility service did not answer. All items have been released.") }
        timeouts[id] = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        do {
            var data = try JSONSerialization.data(withJSONObject: ["id": id, "hidden": hidden]); data.append(10)
            guard let input, data.count <= 65536 else { fail("Invalid visibility service request."); return }
            let written = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
            guard written == data.count else { fail("The visibility service could not accept a request. All items have been released."); return }
        } catch { fail("The visibility service disconnected. All items have been released.") }
    }
    private func start() {
        var url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/IconAbsorberAgent")
        #if TESTING
        url = executableForTesting ?? url
        #endif
        guard FileManager.default.isExecutableFile(atPath: url.path) else { fail("The bundled Icon Absorber service is missing. Rebuild or reinstall Jimmy Tweaks."); return }
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = url; task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.nullDevice
        let token = UUID(); launchToken = token
        process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        let descriptor = stdin.fileHandleForWriting.fileDescriptor
        // Private-service failure must neither SIGPIPE the host nor block its main
        // thread. Partial/full pipes fail open instead of waiting on a stuck service.
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            fail("Could not establish a safe visibility service connection."); return
        }
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.launchToken == token else { return }
                if data.isEmpty { self.fail("The visibility service stopped. All items have been released.") }
                else { self.consume(data) }
            }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.launchToken == token else { return }
                self.fail("The visibility service exited. Other Jimmy Tweaks features continue running.")
            }
        }
        do { try task.run() }
        catch { fail("Could not start the visibility service: \(error.localizedDescription)"); return }
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.launchToken == token, self?.ready == false else { return }
            self?.fail("The visibility service could not initialize on this macOS version.")
        }
        timeouts[0] = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 131072 else { fail("Invalid visibility service response."); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = json["id"] as? Int else { fail("Invalid visibility service response."); return }
            timeouts.removeValue(forKey: id)?.cancel()
            if id == 0 {
                guard json["available"] as? Bool == true else { fail(json["error"] as? String ?? "This macOS version is unsupported."); return }
                ready = true
                if let queued { self.queued = nil; apply(hidden: queued.0, completion: queued.1) }
            } else if json["ok"] as? Bool == true {
                held = json["held"] as? Bool == true
                pending.removeValue(forKey: id)?(.success(held))
            } else { fail(json["error"] as? String ?? "The private visibility API rejected this request."); return }
        }
    }
    private func fail(_ message: String) {
        let callbacks = pending.values.map { $0 }; let waiting = queued?.1
        pending = [:]; queued = nil; stop()
        callbacks.forEach { $0(.failure(Failure.message(message))) }; waiting?(.failure(Failure.message(message)))
        onFailure?(message)
    }
    func stop() {
        launchToken = UUID(); ready = false; held = false
        timeouts.values.forEach { $0.cancel() }; timeouts = [:]
        output?.readabilityHandler = nil; try? input?.close(); try? output?.close()
        input = nil; output = nil; buffer = Data()
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        let callbacks = pending.values.map { $0 }; let waiting = queued?.1; pending = [:]; queued = nil
        callbacks.forEach { $0(.failure(Failure.message("Cancelled"))) }; waiting?(.failure(Failure.message("Cancelled")))
    }
    deinit { stop() }
}
