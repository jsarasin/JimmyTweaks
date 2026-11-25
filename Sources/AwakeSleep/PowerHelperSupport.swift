import Foundation
import Darwin
import MachO

struct PowerHelperFailure: LocalizedError, Codable, Equatable {
    enum Kind: String, Codable { case approval, incompatible, unavailable, restoration, session }
    let kind: Kind
    let detail: String
    var errorDescription: String? { detail }
    var untilReset: Bool { kind == .unavailable }
}

enum PowerHelperSafety {
    /// A permission error is not evidence that recovery state is absent.
    static func recoveryMayExist(at path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        return errno != ENOENT
    }
    static func parseSleepDisabled(_ text: String) throws -> Bool {
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 2, fields[0] == "SleepDisabled", ["0", "1"].contains(fields[1]) {
                return fields[1] == "1"
            }
        }
        throw AwakeSleepError.message("macOS did not report the closed-lid sleep override.")
    }
    /// Read-only and bounded; never run a power-setting command to infer restoration.
    static func sleepDisabled() async throws -> Bool {
        try await Task.detached(priority: .utility) { try readSleepDisabled() }.value
    }
    private static func readSleepDisabled() throws -> Bool {
        let task = Process(), output = Pipe(), done = DispatchSemaphore(value: 0)
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        task.terminationHandler = { _ in done.signal() }
        try task.run()
        guard done.wait(timeout: .now() + 3) == .success else {
            task.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut { kill(task.processIdentifier, SIGKILL) }
            throw AwakeSleepError.message("The read-only sleep-state check timed out.")
        }
        guard task.terminationStatus == 0 else { throw AwakeSleepError.message("Could not read the sleep override.") }
        return try parseSleepDisabled(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    static func executableURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var bytes = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&bytes, &size) == 0 else {
            throw AwakeSleepError.message("Could not resolve the running helper executable.")
        }
        return URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
    }
    static func enclosingApp(executable: URL) throws -> URL {
        let executable = executable.resolvingSymlinksInPath()
        var app = executable
        for _ in 0..<4 { app.deleteLastPathComponent() }
        guard app.pathExtension == "app",
              app.appendingPathComponent("Contents/Library/HelperTools/AwakeSleepHelper").path == executable.path else {
            throw AwakeSleepError.message("The helper is not inside a Jimmy Tweaks app bundle.")
        }
        return app
    }
    static func terminalExitCode(recoveryMayExist: Bool) -> Int32 { recoveryMayExist ? 1 : 0 }
}

/// Main-queue arbitration shared by real XPC requests and deadline/race checks.
final class PowerHelperReplyGate {
    private var completion: ((Result<Void, Error>) -> Void)?
    private var deadline: DispatchWorkItem?
    init(timeout: TimeInterval = 4, schedule: (TimeInterval, DispatchWorkItem) -> Void = {
        DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
    }, completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(.failure(PowerHelperFailure(kind: .unavailable, detail: "The closed-lid helper did not respond. Sleep restoration has not been confirmed. Closed-lid support is disabled until reset.")))
        }
        self.deadline = deadline; schedule(timeout, deadline)
    }
    func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil; deadline?.cancel(); deadline = nil
        completion(result)
    }
    deinit { deadline?.cancel() }
}
