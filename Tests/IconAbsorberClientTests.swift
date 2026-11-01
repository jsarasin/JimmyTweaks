import AppKit
import Darwin

@main struct IconAbsorberClientTests {
    static func main() {
        let client = IconAssertionClient()
        client.executableForTesting = URL(fileURLWithPath: CommandLine.arguments[1])
        var ready = false, failures = 0, completed = false
        client.onFailure = { _ in failures += 1 }
        client.apply(hidden: []) { result in
            guard case .success(false) = result else { fatalError("Real service must accept an empty selection") }
            ready = true
        }
        func wait(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(7)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "Visibility service did not finish in time")
        }
        wait { ready }
        guard let pid = client.processIDForTesting else { fatalError("Missing service process") }
        precondition(!client.held)
        precondition(kill(pid, SIGKILL) == 0)
        // Exercise the write/death race rather than waiting for a clean disconnect.
        client.apply(hidden: []) { result in
            precondition({ if case .failure = result { return true }; return false }())
            completed = true
        }
        wait { completed && failures == 1 }
        precondition(!client.held); client.stop()
        print("Icon Absorber client: real clear acknowledgement and service-kill/write race passed; host survived. No application was hidden.")
    }
}
