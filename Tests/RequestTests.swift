import AppKit

private final class StubRequestOperation: RequestOperation {
    var cancelled = false
    func cancel() { cancelled = true }
}
private final class StubRequestTransport: RequestTransport {
    struct Sent {
        var request: URLRequest
        var operation: StubRequestOperation
        var completion: (RequestResponse) -> Void
    }
    var sent: [Sent] = []
    var invalidated = false
    func send(_ request: URLRequest, completion: @escaping (RequestResponse) -> Void) -> RequestOperation {
        let operation = StubRequestOperation(); sent.append(Sent(request: request, operation: operation, completion: completion)); return operation
    }
    func invalidate() { invalidated = true; sent.forEach { $0.operation.cancel() } }
}
private final class RequestStubProtocol: URLProtocol {
    static let handler = Locked<((URLRequest, URLProtocolClient, URLProtocol) -> Void)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let client, let handler = Self.handler.snapshot { handler(request, client, self) }
    }
    override func stopLoading() {}
}

enum RequestTests {
    private static func settle(until condition: () -> Bool = { false }, timeout: TimeInterval = 0.05) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
    static func run(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try persistence(root: root); schedules(); try controller(); try dailyAdmission(); try transport(); try realHTTP(root: root); try editor(root: root)
        print("Recurring request checks passed: persistence, schedules/DST, manual runs, payloads, responses, cancellation, and editor.")
    }
    private static func definition() -> RequestDefinition {
        var row = RequestDefinition(); row.name = "Private API payload marker"; row.url = "https://api.invalid/test?key=private-query"
        row.method = "POST"; row.headers = [RequestHeader(name: "Authorization", value: "Bearer private-token")]
        row.bodyKind = .json; row.body = "{\"hello\":\"world\"}"; return row
    }
    private static func persistence(root: URL) throws {
        let directory = root.appendingPathComponent("storage")
        let store = RequestStore(directory: directory), row = definition()
        try store.update { $0.enabled = true; $0.requests = [row] }
        let loaded = RequestStore(directory: directory)
        assert(loaded.state.enabled && loaded.state.requests == [row])
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.json").path)
        assert((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        assert((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try store.update { state in
            for _ in 0..<105 { state.history.append(RequestRun(requestID: row.id, name: row.name, started: Date(), duration: 1, statusCode: 200, outcome: "Success")) }
        }
        assert(store.state.history.count == 100 && RequestStore(directory: directory).state.history.count == 100)
        let file = directory.appendingPathComponent("state.json")
        try Data("invalid data".utf8).write(to: file)
        let broken = RequestStore(directory: directory)
        assert(broken.loadError != nil && !broken.state.enabled)
        do { try broken.update { $0.enabled = true }; assertionFailure("Corrupt data must not be overwritten silently") } catch {}
        let untouched = try Data(contentsOf: file)
        assert(String(data: untouched, encoding: .utf8) == "invalid data")
        try broken.update(replacingUnreadableData: true) { $0 = RequestState() }
        assert(broken.loadError == nil && !RequestStore(directory: directory).state.enabled)
        let blocked = root.appendingPathComponent("not-a-directory"); try Data().write(to: blocked)
        let unwritable = RequestStore(directory: blocked)
        do { try unwritable.update { $0.enabled = true }; assertionFailure("Failed save must throw") } catch {}
        assert(!unwritable.state.enabled, "A failed write never activates unsaved configuration")
    }
    private static func schedules() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Edmonton")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let spring = RequestSchedule.daily(hour: 2, minute: 30).next(after: date(2026, 3, 8, 0), calendar: calendar)!
        assert(calendar.component(.hour, from: spring) == 3 && calendar.component(.minute, from: spring) == 0)
        let schedule = RequestSchedule.daily(hour: 1, minute: 30)
        let first = schedule.next(after: date(2026, 11, 1, 0), calendar: calendar)!
        let next = schedule.next(after: first, calendar: calendar)!
        assert(calendar.component(.day, from: next) == 2, "Repeated clock hour must not cause a second daily run")
        assert(schedule.next(after: first.addingTimeInterval(1800), calendar: calendar) == next)
        assert(RequestSchedule.manual.next(after: Date()) == nil)
        assert(RequestSchedule.interval(minutes: 0).next(after: Date()) == nil)
        assert(RequestSchedule.daily(hour: 9, minute: 0).next(after: date(2026, 5, 1, 10), calendar: calendar) == date(2026, 5, 2, 9))
    }
    private static func controller() throws {
        let preferences = PreferenceStore(defaults: MemoryDefaults()), store = RequestStore(), transport = StubRequestTransport()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = RequestController(preferences: preferences, store: store, transport: transport, clock: { now }, uptime: { now.timeIntervalSince1970 }, automaticScheduling: false, observeWorkspace: false)
        let id = try controller.add(); var row = definition(); row.id = id
        try controller.update(row)
        do { try controller.runNow(id); assertionFailure("Disabled module admitted a request") } catch {}
        try controller.setEnabled(true)
        assert(controller.nextRun(id) == nil)
        try controller.runNow(id)
        assert(transport.sent.count == 1 && controller.isRunning(id))
        assert(transport.sent[0].request.httpMethod == "POST" && transport.sent[0].request.httpBody == Data(row.body.utf8))
        assert(transport.sent[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer private-token")
        assert(transport.sent[0].request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        do { try controller.runNow(id); assertionFailure("Overlapping execution admitted") } catch {}
        now = now.addingTimeInterval(3)
        transport.sent[0].completion(RequestResponse(statusCode: 201, body: Data("{\"ok\":true}".utf8)))
        settle(until: { !controller.isRunning(id) })
        assert(controller.state.history.first?.outcome == "Success" && controller.state.history.first?.duration == 3)
        now = now.addingTimeInterval(86_400); controller.tick()
        assert(transport.sent.count == 1, "Manual requests must never be timer-triggered")
        let copy = try controller.duplicate(id)
        assert(controller.state.requests.first(where: { $0.id == copy })?.enabled == false)
        row.schedule = .interval(minutes: 1); row.enabled = true; try controller.update(row)
        let due = controller.nextRun(id)!
        now = due; controller.tick(); assert(transport.sent.count == 2)
        now = now.addingTimeInterval(60); controller.tick(); assert(transport.sent.count == 2, "Busy request is never overlapped")
        preferences.set(true, for: .suspended)
        assert(transport.sent[1].operation.cancelled && !controller.isRunning(id) && controller.nextRun(id) == nil)
        let count = controller.state.history.count
        transport.sent[1].completion(RequestResponse(statusCode: 200)); settle()
        assert(controller.state.history.count == count, "Late completion after cancellation is ignored")
        now = now.addingTimeInterval(7200); preferences.set(false, for: .suspended)
        assert(controller.nextRun(id) == now.addingTimeInterval(60))
        controller.tick(); assert(transport.sent.count == 2)
        now = now.addingTimeInterval(3600); controller.tick()
        assert(transport.sent.count == 2, "Delayed timer skips overdue requests")
        controller.setSleeping(true); now = now.addingTimeInterval(3600); controller.setSleeping(false)
        assert(controller.nextRun(id) == now.addingTimeInterval(60))
        controller.setSessionActive(false); assert(controller.nextRun(id) == nil)
        controller.setSessionActive(true); assert(controller.nextRun(id) == now.addingTimeInterval(60))
        try controller.runNow(id); let pending = transport.sent.last!
        try controller.remove(id); assert(pending.operation.cancelled && !controller.isRunning(id))
        try controller.runNow(copy); let last = transport.sent.last!
        controller.shutdown()
        assert(last.operation.cancelled && transport.invalidated && controller.stopped && !controller.available && controller.nextRun(copy) == nil)
        last.completion(RequestResponse(statusCode: 200)); settle()
        assert(controller.state.history.first?.outcome == "Cancelled")
        do { try controller.runNow(copy); assertionFailure("Shutdown allowed another request") } catch {}
    }
    private static func dailyAdmission() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 8))!
        var now = morning
        let preferences = PreferenceStore(defaults: MemoryDefaults()), store = RequestStore(), transport = StubRequestTransport()
        var row = definition(); row.schedule = .daily(hour: 9, minute: 0); row.enabled = true
        try store.update { $0.enabled = true; $0.requests = [row] }
        let controller = RequestController(preferences: preferences, store: store, transport: transport, clock: { now }, calendar: { calendar }, automaticScheduling: false, observeWorkspace: false)
        now = morning.addingTimeInterval(3600); controller.tick()
        assert(transport.sent.count == 1)
        transport.sent[0].completion(RequestResponse(statusCode: 200)); settle(until: { !controller.isRunning(row.id) })
        try controller.clearHistory()
        now = morning; controller.reschedule()
        assert(controller.nextRun(row.id) == morning.addingTimeInterval(25 * 3600), "Clock rollback and cleared history must not admit a second daily request")
        controller.shutdown()
        let relaunched = RequestController(preferences: preferences, store: store, transport: StubRequestTransport(), clock: { now }, calendar: { calendar }, automaticScheduling: true, observeWorkspace: false)
        assert(relaunched.nextRun(row.id) == morning.addingTimeInterval(25 * 3600) && relaunched.hasTimerForTesting)
        relaunched.shutdown(); assert(!relaunched.hasTimerForTesting && relaunched.nextRun(row.id) == nil)
    }
    private static func transport() throws {
        let transport = HTTPRequestTransport(configuration: {
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RequestStubProtocol.self]; return configuration
        })
        var row = definition()
        for method in RequestDefinition.methods {
            row.method = method
            let request = try row.makeURLRequest()
            assert(request.httpMethod == method)
            assert((request.httpBody != nil) == row.allowsBody)
        }
        row.method = "POST"
        row.headers.append(RequestHeader(name: "Content-Type", value: "application/custom+json"))
        let custom = try row.makeURLRequest()
        assert(custom.value(forHTTPHeaderField: "Content-Type") == "application/custom+json")
        RequestStubProtocol.handler.withValue { handler in handler = { request, client, source in
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer private-token")
            client.urlProtocol(source, didReceive: HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: "HTTP/1.1", headerFields: ["X-Reply": "present"])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(source, didLoad: Data(repeating: 65, count: 40_000))
            client.urlProtocol(source, didLoad: Data(repeating: 66, count: 40_000)); client.urlProtocolDidFinishLoading(source)
        } }
        var result: RequestResponse?
        _ = transport.send(try row.makeURLRequest()) { result = $0 }
        settle(until: { result != nil }, timeout: 3)
        assert(result?.statusCode == 422 && result?.body.count == 65_536 && result?.truncated == true)
        assert(result?.headers.contains { $0.name.caseInsensitiveCompare("X-Reply") == .orderedSame && $0.value == "present" } == true)
        RequestStubProtocol.handler.withValue { $0 = { _, client, source in client.urlProtocol(source, didFailWithError: URLError(.timedOut)) } }
        result = nil; _ = transport.send(try row.makeURLRequest()) { result = $0 }
        settle(until: { result != nil }, timeout: 3); assert(result?.failure == "Timed out")
        RequestStubProtocol.handler.withValue { $0 = { _, _, _ in } }
        result = nil; let operation = transport.send(try row.makeURLRequest()) { result = $0 }; operation.cancel()
        settle(until: { result != nil }, timeout: 3); assert(result?.failure == "Cancelled")
        transport.invalidate(); RequestStubProtocol.handler.withValue { $0 = nil }
    }
    private static func realHTTP(root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/RequestServer.py")
        let portFile = root.appendingPathComponent("port-" + UUID().uuidString)
        process.arguments = [fixture.path, portFile.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        settle(until: { FileManager.default.fileExists(atPath: portFile.path) || !process.isRunning }, timeout: 4)
        guard process.isRunning, let port = try? String(contentsOf: portFile, encoding: .utf8), Int(port) != nil else {
            throw RequestError.message("Loopback HTTP fixture could not start.")
        }
        let base = "http://127.0.0.1:" + port
        let transport = HTTPRequestTransport(); defer { transport.invalidate() }
        var row = definition(); row.url = base + "/echo"
        var response: RequestResponse?
        _ = transport.send(try row.makeURLRequest()) { response = $0 }
        settle(until: { response != nil }, timeout: 4)
        assert(response?.statusCode == 201 && response?.failure == nil)
        let echo = try JSONSerialization.jsonObject(with: response!.body) as! [String: String]
        assert(echo["method"] == "POST" && echo["authorization"] == "Bearer private-token" && echo["body"] == row.body && echo["contentType"] == "application/json")
        row.method = "GET"; row.url = base + "/redirect"; response = nil
        _ = transport.send(try row.makeURLRequest()) { response = $0 }
        settle(until: { response != nil }, timeout: 4)
        assert(response?.statusCode == 302 && String(data: response!.body, encoding: .utf8) == "redirect response", "Never follow API redirects automatically")
        row.url = base + "/large"; response = nil
        _ = transport.send(try row.makeURLRequest()) { response = $0 }
        settle(until: { response != nil }, timeout: 4)
        assert(response?.statusCode == 200 && response?.truncated == true && response?.body.count == 65_536)
        row.url = base + "/slow"; response = nil
        let operation = transport.send(try row.makeURLRequest()) { response = $0 }
        operation.cancel(); settle(until: { response != nil }, timeout: 4)
        assert(response?.failure == "Cancelled")
        print("Loopback HTTP checks passed: exact JSON/auth payload, response status/body, no redirects, truncation, and cancellation.")
    }
    private static func editor(root: URL) throws {
        let preferences = PreferenceStore(defaults: MemoryDefaults()); preferences.set(true, for: .suspended)
        let logger = FileLogger(directory: root.appendingPathComponent("editor-logs"), maintenance: false)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false }, checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let runtime = RuntimeCoordinator(preferences: preferences, permissions: permissions, logger: logger)
        let transport = StubRequestTransport()
        let controller = RequestController(preferences: preferences, store: RequestStore(), transport: transport, automaticScheduling: false, observeWorkspace: false)
        let context = SettingsContext(preferences: preferences, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: preferences), requests: controller)
        let page = ScriptsPageController(.scripts, context: context); _ = page.view
        let id = try controller.add(); page.selectRequest(id)
        (page.controls["scripts.url"] as! CommitField).stringValue = "http://localhost:8080/api"
        (page.controls["scripts.name"] as! CommitField).stringValue = "Never index this private API"
        let method = page.controls["scripts.method"] as! ActionPopup
        method.selectItem(withTitle: "POST"); method.handler?(method.indexOfSelectedItem)
        let kind = page.controls["scripts.bodyKind"] as! ActionPopup
        kind.selectItem(withTitle: "JSON"); kind.handler?(kind.indexOfSelectedItem)
        (page.controls["scripts.body"] as! NSTextView).string = "{\"test\":true}"
        (page.controls["scripts.headers.add"] as! ActionButton).handler?()
        let headerName = page.controls["scripts.header.0.name"] as! CommitField
        let headerValue = page.controls["scripts.header.0.value"] as! CommitField
        headerName.stringValue = "X-API-Key"; headerName.commit?(headerName.stringValue)
        headerValue.stringValue = "private-key-marker"; headerValue.commit?(headerValue.stringValue)
        (page.controls["scripts.save"] as! ActionButton).handler?()
        assert(controller.state.requests[0].url == "http://localhost:8080/api" && controller.state.requests[0].body == "{\"test\":true}")
        assert(controller.state.requests[0].headers == [RequestHeader(name: "X-API-Key", value: "private-key-marker")])
        assert(controller.state.requests[0].schedule == .manual && controller.nextRun(id) == nil)
        assert(context.catalog.search("private-key-marker").isEmpty && context.catalog.search("Never index").isEmpty)
        let run = page.controls["scripts.run"] as! ActionButton
        assert(run.title == "Run Once" && !run.isEnabled)
        try controller.setEnabled(true); preferences.set(false, for: .suspended); page.refreshValues()
        assert(run.isEnabled); run.handler?(); assert(transport.sent.count == 1)
        transport.sent[0].completion(RequestResponse(statusCode: 200, headers: [RequestHeader(name: "X-Response", value: "yes")], body: Data("<script>inert</script>".utf8)))
        settle(until: { !controller.isRunning(id) }); page.refreshValues()
        page.historyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        assert((page.controls["scripts.response"] as! NSTextView).string.contains("<script>inert</script>"))
        let schedule = page.controls["scripts.schedule"] as! ActionPopup
        schedule.selectItem(withTitle: "Daily at time"); schedule.handler?(schedule.indexOfSelectedItem)
        (page.controls["scripts.time"] as! CommitField).stringValue = "10:30"
        (page.controls["scripts.rowEnabled"] as! ActionButton).state = .on
        (page.controls["scripts.save"] as! ActionButton).handler?()
        assert(controller.state.requests[0].schedule == .daily(hour: 10, minute: 30) && controller.nextRun(id) != nil)
        let settings = SettingsWindowController(context: context)
        settings.showWindow(nil); context.navigate?(SearchDestination(page: .scripts, controlID: ""))
        let window = settings.window!
        func snapshot(_ name: String) throws {
            settle(timeout: 0.1); window.layoutIfNeeded()
            let content = window.contentView!, bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
        }
        window.setContentSize(NSSize(width: 960, height: 700)); try snapshot("requests-960")
        window.setContentSize(NSSize(width: 780, height: 700)); try snapshot("requests-780")
        context.navigate?(SearchDestination(page: .scripts, controlID: "scripts.body")); try snapshot("requests-editor-780")
        let visiblePage = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? ScriptsPageController }.first!
        let editorScroll = visiblePage.controls["scripts.body"]!.enclosingScrollView!
        let editorRect = visiblePage.scroll.documentView!.convert(editorScroll.bounds, from: editorScroll)
        assert(visiblePage.scroll.documentVisibleRect.intersects(editorRect), "Search must scroll the outer page to nested text editors")
        context.navigate?(SearchDestination(page: .scripts, controlID: "scripts.response")); try snapshot("requests-response-780")
        settings.close(); assert(!controller.stopped && controller.nextRun(id) != nil, "Closing Settings must preserve scheduling")
        controller.shutdown(); preferences.set(true, for: .suspended)
        logger.shutdown {}
    }
}
