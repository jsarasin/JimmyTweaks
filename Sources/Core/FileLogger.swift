import Foundation

enum LogRetention {
    static func timestamp(_ line: Substring) -> Date? {
        guard let first = line.split(separator: "\t", maxSplits: 1).first else { return nil }
        return ISO8601DateFormatter().date(from: String(first))
    }
    static func clean(directory: URL, active: URL?, now: Date) throws {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-168 * 3600)
        let pattern = #"^Jimmy-Tweaks-\d{4}-\d{2}-\d{2}(?:-\d+)?\.log$"#
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) {
            guard file != active, file.lastPathComponent.range(of: pattern, options: .regularExpression) != nil else { continue }
            let resource = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let dates = lines.compactMap(timestamp)
            guard let newest = dates.max() else {
                if let modified = resource.contentModificationDate, modified < cutoff { try fm.removeItem(at: file) }
                continue
            }
            if newest < cutoff { try fm.removeItem(at: file); continue }
            let retained = lines.filter { line in timestamp(line).map { $0 >= cutoff } ?? true }
            if retained.count != lines.count {
                try (retained.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
    }
}

final class FileLogger: @unchecked Sendable {
    struct Status { var path: String?; var error: String? }
    let directory: URL
    private let queue = DispatchQueue(label: "app.jimmytweaks.log", qos: .utility)
    private let state = Locked(Status())
    private let clock: () -> Date
    private var handle: FileHandle?
    private var file: URL?
    private var fileDay = ""
    private var segment = 0
    private var byteCount: UInt64 = 0
    private var buffered: [String] = []
    private var retryAfter = Date.distantPast
    private var rateLimits: [String: (Date, Int)] = [:]
    private var timer: DispatchSourceTimer?
    private let formatter = ISO8601DateFormatter()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    var status: Status { state.snapshot }

    init(directory: URL? = nil, clock: @escaping () -> Date = Date.init, maintenance: Bool = true) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jimmy Tweaks", isDirectory: true)
        self.clock = clock
        if maintenance {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in self?.maintain() }
            timer.resume(); self.timer = timer
        }
        queue.async { [weak self] in self?.maintain() }
    }
    deinit { timer?.cancel(); try? handle?.close() }
    func log(_ component: String, _ event: String, _ message: String, severity: String = "INFO") {
        queue.async { [weak self] in self?.append(component, event, message, severity: severity) }
    }
    func rateLimited(_ key: String, component: String, event: String, message: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let now = self.clock()
            if let record = self.rateLimits[key], now.timeIntervalSince(record.0) < 60 {
                self.rateLimits[key] = (record.0, record.1 + 1); return
            }
            let count = self.rateLimits[key]?.1 ?? 0
            self.rateLimits[key] = (now, 0)
            self.rateLimits = self.rateLimits.filter { now.timeIntervalSince($0.value.0) < 3600 }
            self.append(component, event, message + (count > 0 ? " (\(count) repeated errors suppressed)" : ""), severity: "WARN")
        }
    }
    func retry() { queue.async { [weak self] in self?.retryAfter = .distantPast; self?.append("logging", "retry", "Log writer retry requested.", severity: "INFO") } }
    func flush(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.openIfNeeded()
                try self.drainBuffered()
                try self.handle?.synchronize()
                guard let url = self.file else { throw CocoaError(.fileNoSuchFile) }
                self.retryAfter = .distantPast
                DispatchQueue.main.async { completion(.success(url)) }
            } catch { self.failed(error); DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func shutdown(completion: @escaping () -> Void) {
        queue.async { [self] in
            do {
                try openIfNeeded()
                try drainBuffered()
                try handle?.synchronize()
            } catch { failed(error) }
            try? handle?.close(); handle = nil; timer?.cancel()
            DispatchQueue.main.async(execute: completion)
        }
    }
    private func safe(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ") }
    private func append(_ component: String, _ event: String, _ message: String, severity: String) {
        let line = "\(formatter.string(from: clock()))\t\(safe(severity))\t\(safe(component))\t\(safe(event))\t\(safe(message))\n"
        guard clock() >= retryAfter else { retain(line); return }
        do {
            try drainBuffered()
            try openIfNeeded()
            try write(line)
            if state.snapshot.error != nil { state.withValue { $0.error = nil }; announce() }
        } catch { retain(line); failed(error) }
    }
    private func retain(_ line: String) { buffered.append(line); if buffered.count > 200 { buffered.removeFirst(buffered.count - 200) } }
    private func drainBuffered() throws {
        while let line = buffered.first {
            try openIfNeeded()
            try write(line)
            buffered.removeFirst()
        }
    }
    private func write(_ line: String) throws {
        let data = Data(line.utf8)
        try handle?.write(contentsOf: data); byteCount += UInt64(data.count)
    }
    private func openIfNeeded() throws {
        let now = clock(), day = dayFormatter.string(from: now)
        if handle != nil, day == fileDay, byteCount < 5 * 1024 * 1024 { return }
        try handle?.synchronize(); try handle?.close(); handle = nil
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if day != fileDay { segment = 0 }
        fileDay = day
        while true {
            let suffix = segment == 0 ? "" : "-\(segment)"
            let url = directory.appendingPathComponent("Jimmy-Tweaks-\(day)\(suffix).log")
            if fm.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
                let bytes = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                if bytes >= 5 * 1024 * 1024 { segment += 1; continue }
            } else {
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            handle = try FileHandle(forWritingTo: url)
            byteCount = try handle!.seekToEnd(); file = url
            state.withValue { $0.path = url.path; $0.error = nil }; announce()
            if byteCount == 0 { try write("\(formatter.string(from: now))\tINFO\tlogging\tfile.open\tNormal logging; local plain-text records, seven-day retention.\n") }
            try LogRetention.clean(directory: directory, active: url, now: now)
            return
        }
    }
    private func maintain() {
        do { try openIfNeeded(); try LogRetention.clean(directory: directory, active: file, now: clock()) }
        catch { failed(error) }
    }
    private func failed(_ error: Error) {
        try? handle?.close(); handle = nil; retryAfter = clock().addingTimeInterval(30)
        state.withValue { $0.error = "The local log could not be written. Check folder access or try again." }
        announce()
    }
    private func announce() { DispatchQueue.main.async { [weak self] in NotificationCenter.default.post(name: .loggingChanged, object: self) } }
}
