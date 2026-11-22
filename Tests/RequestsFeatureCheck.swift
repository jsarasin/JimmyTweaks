import AppKit

@main struct RequestsFeatureCheck {
    static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try RequestTests.run(root: root)
    }
}
