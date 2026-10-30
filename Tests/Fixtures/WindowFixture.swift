import AppKit

final class FixtureWindow: NSWindow {
    var rejectGeometry = false
    var delayGeometry = false
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if rejectGeometry { return }; if delayGeometry { Thread.sleep(forTimeInterval: 0.15) }
        super.setFrame(frameRect, display: flag)
    }
}
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: FixtureWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = FixtureWindow(contentRect: NSRect(x: 180, y: 180, width: 560, height: 350), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Jimmy Tweaks — AX Test Fixture"; window.minSize = NSSize(width: 250, height: 180)
        let text = NSTextField(wrappingLabelWithString: "Cooperative fixture: drag any corner with Command + right-button, or move the interior with Command + left-button. Choose constrained, rejected, delayed, or invalidated targets from the buttons below. This tool is separate from the shipped app.")
        let buttons = [NSButton(title: "Clamp Size", target: self, action: #selector(clamp)), NSButton(title: "Reject Geometry", target: self, action: #selector(reject)), NSButton(title: "Delay Geometry", target: self, action: #selector(delay)), NSButton(title: "Close Target", target: self, action: #selector(closeTarget))]
        let stack = NSStackView(views: [text] + buttons); stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func clamp() { window.minSize = NSSize(width: 400, height: 300); window.maxSize = NSSize(width: 720, height: 520) }
    @objc func reject() { window.rejectGeometry.toggle() }
    @objc func delay() { window.delayGeometry.toggle() }
    @objc func closeTarget() { window.close() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = FixtureDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
