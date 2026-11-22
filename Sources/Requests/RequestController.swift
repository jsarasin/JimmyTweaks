import AppKit

extension Notification.Name { static let requestsChanged = Notification.Name("JimmyTweaks.requestsChanged") }

struct RequestResponse {
    var statusCode: Int?
    var headers: [RequestHeader] = []
    var body = Data()
    var truncated = false
    var failure: String?
}
protocol RequestOperation: AnyObject { func cancel() }
protocol RequestTransport: AnyObject {
    func send(_ request: URLRequest, completion: @escaping (RequestResponse) -> Void) -> RequestOperation
    func invalidate()
}

extension RequestDefinition {
    func makeURLRequest() throws -> URLRequest {
        if let error = validationError { throw RequestError.message(error) }
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        for header in headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        if allowsBody && bodyKind != .none {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(bodyKind == .json ? "application/json" : "text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }
}

/// Ephemeral data tasks only: no daemon, background transfer session, disk cache, or interpreter.
final class HTTPRequestTransport: RequestTransport {
    private let configuration: () -> URLSessionConfiguration
    private var exchanges: [UUID: HTTPExchange] = [:]
    init(configuration: @escaping () -> URLSessionConfiguration = { .ephemeral }) { self.configuration = configuration }
    func send(_ request: URLRequest, completion: @escaping (RequestResponse) -> Void) -> RequestOperation {
        let id = UUID()
        let config = configuration()
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        let exchange = HTTPExchange(configuration: config) { [weak self] result in
            self?.exchanges.removeValue(forKey: id); completion(result)
        }
        exchanges[id] = exchange; exchange.start(request)
        return exchange
    }
    func invalidate() {
        let pending = Array(exchanges.values); exchanges.removeAll()
        pending.forEach { $0.cancel() }
    }
    deinit { exchanges.values.forEach { $0.cancel() } }
}

private final class HTTPExchange: NSObject, URLSessionDataDelegate, RequestOperation, @unchecked Sendable {
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var response = RequestResponse()
    private let completion: (RequestResponse) -> Void
    init(configuration: URLSessionConfiguration, completion: @escaping (RequestResponse) -> Void) {
        self.completion = completion
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func start(_ request: URLRequest) { task = session.dataTask(with: request); task?.resume() }
    func cancel() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Trust evaluation remains native; authentication comes from the configured headers.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            self.response.statusCode = http.statusCode
            var remaining = 16_384
            for (key, value) in http.allHeaderFields.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
                let name = String(describing: key), text = String(describing: value)
                let cost = name.utf8.count + text.utf8.count
                if cost <= remaining { self.response.headers.append(RequestHeader(name: name, value: text)); remaining -= cost }
            }
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let remaining = max(0, 65_536 - response.body.count)
        response.body.append(data.prefix(remaining))
        if data.count > remaining { response.truncated = true }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: response.failure = "Cancelled"
            case .timedOut: response.failure = "Timed out"
            case .notConnectedToInternet, .networkConnectionLost: response.failure = "Network unavailable"
            case .cannotFindHost, .dnsLookupFailed: response.failure = "Host could not be resolved"
            case .cannotConnectToHost: response.failure = "Could not connect to host"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed: response.failure = "TLS certificate or connection failed"
            default: response.failure = "Network error (\(error.code.rawValue))"
            }
        } else if error != nil { response.failure = "Request failed" }
        let result = response
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { [completion] in completion(result) }
    }
}

/// Main-queue scheduler, independent of the input engine and Settings window.
final class RequestController {
    private struct Active {
        let runID: UUID
        let definition: RequestDefinition
        let started: Date
        let uptime: TimeInterval
        var operation: RequestOperation?
    }
    let store: RequestStore
    private let preferences: PreferenceStore
    private let transport: RequestTransport
    private let clock: () -> Date
    private let uptime: () -> TimeInterval
    private let calendar: () -> Calendar
    private let automaticScheduling: Bool
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchWorkItem?
    private var active: [UUID: Active] = [:]
    private var nextRuns: [UUID: Date] = [:]
    private var scheduledDefinitions: [UUID: RequestDefinition] = [:]
    private var sleeping = false
    private var sessionActive = true
    private(set) var stopped = false
    private(set) var error: String?
    var state: RequestState { store.state }
    var available: Bool { !stopped && state.enabled && store.loadError == nil && !preferences.bool(.suspended) && !sleeping && sessionActive }
    var status: String {
        if let error = error ?? store.loadError { return error }
        if stopped { return "Stopped" }
        if !state.enabled { return "Requests are off. Enable Recurring Requests to run saved requests." }
        if preferences.bool(.suspended) { return "Paused by Suspend All." }
        if sleeping || !sessionActive { return "Paused until this Mac and user session are active." }
        return "\(active.count) running · \(nextRuns.count) scheduled. Missed runs are skipped."
    }
    init(preferences: PreferenceStore, store: RequestStore, transport: RequestTransport = HTTPRequestTransport(),
         clock: @escaping () -> Date = Date.init, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         calendar: @escaping () -> Calendar = { .current }, automaticScheduling: Bool = true, observeWorkspace: Bool = true) {
        self.preferences = preferences; self.store = store; self.transport = transport
        self.clock = clock; self.uptime = uptime; self.calendar = calendar; self.automaticScheduling = automaticScheduling
        observers.append(NotificationCenter.default.addObserver(forName: .preferencesChanged, object: preferences, queue: .main) { [weak self] _ in self?.reconcile() })
        if observeWorkspace {
            let workspace = NSWorkspace.shared.notificationCenter
            observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(true) })
            observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(false) })
            observers.append(workspace.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in self?.shutdown() })
            observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setSessionActive(false) })
            observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setSessionActive(true) })
            for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reschedule() })
            }
        }
        reconcile()
    }
    deinit {
        timer?.cancel(); active.values.forEach { $0.operation?.cancel() }; transport.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func isRunning(_ id: UUID) -> Bool { active[id] != nil }
    func nextRun(_ id: UUID) -> Date? { nextRuns[id] }
    func setEnabled(_ enabled: Bool) throws { try save { $0.enabled = enabled } }
    @discardableResult func add() throws -> UUID {
        let definition = RequestDefinition()
        try save { $0.requests.append(definition) }; return definition.id
    }
    @discardableResult func duplicate(_ id: UUID) throws -> UUID {
        guard var copy = state.requests.first(where: { $0.id == id }) else { throw RequestError.message("Select a request first.") }
        copy.id = UUID(); copy.name = String((copy.name + " Copy").prefix(80)); copy.enabled = false
        try save { $0.requests.append(copy) }; return copy.id
    }
    func update(_ definition: RequestDefinition) throws {
        if let error = definition.validationError { throw RequestError.message(error) }
        guard let index = state.requests.firstIndex(where: { $0.id == definition.id }) else { throw RequestError.message("This request was removed.") }
        try save { $0.requests[index] = definition }
    }
    func remove(_ id: UUID) throws {
        try save { $0.requests.removeAll { $0.id == id }; $0.lastDailyRuns.removeValue(forKey: id.uuidString) }
    }
    func clearHistory() throws { try save { $0.history.removeAll() } }
    func reset() throws {
        cancelAll()
        try store.update(replacingUnreadableData: true) { $0 = RequestState() }
        error = nil; reconcile()
    }
    private func save(_ change: (inout RequestState) -> Void) throws {
        do { try store.update(change); error = nil; reconcile() }
        catch { self.error = error.localizedDescription; changed(); throw error }
    }
    func runNow(_ id: UUID) throws {
        guard available else { throw RequestError.message("Enable Recurring Requests and resume Jimmy Tweaks before running a request.") }
        guard let definition = state.requests.first(where: { $0.id == id }) else { throw RequestError.message("Select a saved request first.") }
        guard !isRunning(id) else { throw RequestError.message("This request is already running.") }
        try start(definition); changed()
    }
    private func start(_ definition: RequestDefinition, scheduled: Bool = false) throws {
        let request = try definition.makeURLRequest()
        if scheduled, case .daily = definition.schedule {
            // Retain this admission separately from bounded/clearable history, including
            // across relaunch and a clock change backwards within the same local day.
            try store.update { $0.lastDailyRuns[definition.id.uuidString] = clock() }
        }
        let runID = UUID()
        active[definition.id] = Active(runID: runID, definition: definition, started: clock(), uptime: uptime())
        let operation = transport.send(request) { [weak self] response in
            // Serialize even a synchronously completing injected transport after registration.
            DispatchQueue.main.async { self?.finish(definition.id, runID: runID, response: response) }
        }
        active[definition.id]?.operation = operation
    }
    private func finish(_ id: UUID, runID: UUID, response: RequestResponse) {
        guard !stopped, let run = active[id], run.runID == runID else { return }
        active.removeValue(forKey: id)
        let outcome = response.failure ?? response.statusCode.map { (200..<300).contains($0) ? "Success" : "HTTP \($0)" } ?? "No HTTP response"
        append(run, outcome: outcome, response: response); changed()
    }
    private func append(_ run: Active, outcome: String, response: RequestResponse = RequestResponse()) {
        let record = RequestRun(requestID: run.definition.id, name: run.definition.name, started: run.started,
                                duration: max(0, uptime() - run.uptime), statusCode: response.statusCode,
                                outcome: outcome, headers: response.headers, body: Data(response.body.prefix(65_536)),
                                truncated: response.truncated || response.body.count > 65_536)
        do { try store.update { $0.history.insert(record, at: 0) }; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func cancel(_ id: UUID) {
        guard let run = active.removeValue(forKey: id) else { return }
        run.operation?.cancel(); append(run, outcome: "Cancelled"); changed()
    }
    private func cancelAll() { for id in Array(active.keys) { cancel(id) } }
    func setSleeping(_ value: Bool) { sleeping = value; reconcile() }
    func setSessionActive(_ value: Bool) { sessionActive = value; reconcile() }
    func reschedule() { nextRuns.removeAll(); scheduledDefinitions.removeAll(); reconcile() }
    func reconcile() {
        timer?.cancel(); timer = nil
        guard !stopped else { return }
        guard available else {
            nextRuns.removeAll(); scheduledDefinitions.removeAll(); cancelAll(); changed(); return
        }
        let definitions = Dictionary(uniqueKeysWithValues: state.requests.map { ($0.id, $0) })
        for id in Array(active.keys) {
            // Editing a request affects its next run; disabling/removing it cancels current work.
            if definitions[id] == nil || (active[id]?.definition.enabled == true && definitions[id]?.enabled != true) { cancel(id) }
        }
        let eligible = state.requests.filter { $0.enabled && $0.schedule != .manual && $0.validationError == nil }
        let ids = Set(eligible.map(\.id))
        nextRuns = nextRuns.filter { ids.contains($0.key) }
        scheduledDefinitions = scheduledDefinitions.filter { ids.contains($0.key) }
        for definition in eligible where scheduledDefinitions[definition.id] != definition || nextRuns[definition.id] == nil {
            nextRuns[definition.id] = nextDate(for: definition, after: clock())
            scheduledDefinitions[definition.id] = definition
        }
        armTimer(); changed()
    }
    /// Public to deterministic tests; production admission is driven by a single cancellable timer.
    func tick() {
        guard available else { return }
        let now = clock()
        for definition in state.requests {
            guard let due = nextRuns[definition.id], due <= now else { continue }
            nextRuns[definition.id] = nextDate(for: definition, after: now)
            // A delayed wake/event loop must never replay overdue API mutations.
            guard now.timeIntervalSince(due) < 5, !isRunning(definition.id) else { continue }
            do { try start(definition, scheduled: true) } catch { self.error = error.localizedDescription }
        }
        armTimer(); changed()
    }
    private func armTimer() {
        timer?.cancel(); timer = nil
        guard automaticScheduling, available, let next = nextRuns.values.min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, next.timeIntervalSince(clock())), execute: work)
    }
    private func nextDate(for definition: RequestDefinition, after now: Date) -> Date? {
        let calendar = calendar()
        guard let next = definition.schedule.next(after: now, calendar: calendar) else { return nil }
        if case .daily = definition.schedule, let last = state.lastDailyRuns[definition.id.uuidString], calendar.isDate(last, inSameDayAs: next) {
            return definition.schedule.next(after: next, calendar: calendar)
        }
        return next
    }
    func shutdown() {
        guard !stopped else { return }
        timer?.cancel(); timer = nil; nextRuns.removeAll(); scheduledDefinitions.removeAll()
        cancelAll(); stopped = true; transport.invalidate(); changed()
    }
    private func changed() { NotificationCenter.default.post(name: .requestsChanged, object: self) }
    #if TESTING
    var hasTimerForTesting: Bool { timer != nil }
    #endif
}
