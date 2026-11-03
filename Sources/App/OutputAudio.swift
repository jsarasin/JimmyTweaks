import AppKit
import CoreAudio

struct AudioEndpoint: Equatable { let id: UInt32; let uid: String }
struct AudioGain: Equatable { let channel: UInt32; var value: Float32 }
struct AudioMute: Equatable { let channel: UInt32; let muted: Bool }
struct AudioFeedback {
    let volume: Float32?
    let muted: Bool
    var text: String { muted ? "Output muted" : volume.map { "Output volume: \(Int(($0 * 100).rounded()))%" } ?? "Output unmuted" }
}
protocol OutputAudioHardware {
    func defaultOutput() throws -> AudioEndpoint
    func gains(_ device: UInt32) throws -> [AudioGain]
    func setGain(_ device: UInt32, channel: UInt32, value: Float32) throws
    func mutes(_ device: UInt32) throws -> [AudioMute]
    func setMute(_ device: UInt32, channel: UInt32, muted: Bool) throws
}
enum OutputAudioError: LocalizedError {
    case unavailable, unsupported, failed(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "No active sound output device is available."
        case .unsupported: return "This output device does not offer volume control. Use its own volume control."
        case .failed: return "The sound output device did not accept the change."
        }
    }
}

/// All operations are serialized by the status item, and resolve the current
/// default media output afresh. Alert/system-sound routing is left untouched.
final class OutputAudioController {
    private let hardware: OutputAudioHardware
    private var softwareMutes: [String: [AudioGain]] = [:]
    init(hardware: OutputAudioHardware = CoreAudioOutputHardware()) { self.hardware = hardware }
    private func apply(_ gains: [AudioGain], device: UInt32, original: [AudioGain]) throws {
        var written: [UInt32] = []
        do {
            for gain in gains { try hardware.setGain(device, channel: gain.channel, value: gain.value); written.append(gain.channel) }
        } catch {
            for gain in original where written.contains(gain.channel) { try? hardware.setGain(device, channel: gain.channel, value: gain.value) }
            throw error
        }
    }
    private func apply(_ controls: [AudioMute], device: UInt32, muted: Bool) throws {
        var written: [UInt32] = []
        do {
            for control in controls { try hardware.setMute(device, channel: control.channel, muted: muted); written.append(control.channel) }
        } catch {
            for control in controls where written.contains(control.channel) { try? hardware.setMute(device, channel: control.channel, muted: control.muted) }
            throw error
        }
    }
    func adjust(by delta: Float32) throws -> AudioFeedback {
        guard delta.isFinite else { throw OutputAudioError.unsupported }
        let device = try hardware.defaultOutput()
        let original = try hardware.gains(device.id)
        var gains = original
        guard !gains.isEmpty else { throw OutputAudioError.unsupported }
        if let saved = softwareMutes[device.uid] { gains = saved }
        let peak = gains.map(\.value).max() ?? 0
        let next = min(1, max(0, peak + delta))
        let changes = gains.map { gain -> AudioGain in
            let value = peak > 0.00001 ? gain.value * next / peak : next
            return AudioGain(channel: gain.channel, value: value)
        }
        try apply(changes, device: device.id, original: original)
        do { try apply(hardware.mutes(device.id), device: device.id, muted: false) }
        catch { try? apply(original, device: device.id, original: changes); throw error }
        softwareMutes.removeValue(forKey: device.uid)
        return AudioFeedback(volume: next, muted: false)
    }
    func toggleMute() throws -> AudioFeedback {
        let device = try hardware.defaultOutput()
        let mutes = try hardware.mutes(device.id)
        if !mutes.isEmpty {
            let muted = !mutes.contains(where: \.muted)
            try apply(mutes, device: device.id, muted: muted)
            return AudioFeedback(volume: try? hardware.gains(device.id).map(\.value).max(), muted: muted)
        }
        let gains = try hardware.gains(device.id)
        guard !gains.isEmpty else { throw OutputAudioError.unsupported }
        if let saved = softwareMutes[device.uid] {
            try apply(saved, device: device.id, original: gains)
            softwareMutes.removeValue(forKey: device.uid)
            return AudioFeedback(volume: saved.map(\.value).max(), muted: false)
        }
        try apply(gains.map { AudioGain(channel: $0.channel, value: 0) }, device: device.id, original: gains)
        softwareMutes[device.uid] = gains
        return AudioFeedback(volume: gains.map(\.value).max(), muted: true)
    }
}

struct CoreAudioOutputHardware: OutputAudioHardware {
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput, channel: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: channel)
    }
    private func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, initial: T) throws -> T {
        var property = property, value = initial, size = UInt32(MemoryLayout<T>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0) }
        guard result == noErr else { throw OutputAudioError.failed(result) }
        return value
    }
    private func writable(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property, settable: DarwinBoolean = false
        return AudioObjectHasProperty(object, &property) && AudioObjectIsPropertySettable(object, &property, &settable) == noErr && settable.boolValue
    }
    private func write<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, value: T) throws {
        var property = property, value = value
        let result = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        guard result == noErr else { throw OutputAudioError.failed(result) }
    }
    func defaultOutput() throws -> AudioEndpoint {
        let id: UInt32 = try read(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal), initial: 0)
        guard id != kAudioObjectUnknown else { throw OutputAudioError.unavailable }
        let uid: CFString? = try read(id, address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal), initial: Optional<CFString>.none)
        return AudioEndpoint(id: id, uid: uid as String? ?? "device-\(id)")
    }
    private func channels(_ device: UInt32, selector: AudioObjectPropertySelector) throws -> [UInt32] {
        if writable(device, address(selector)) { return [kAudioObjectPropertyElementMain] }
        var property = address(kAudioDevicePropertyStreamConfiguration), size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size)
        guard status == noErr, size >= MemoryLayout<AudioBufferList>.size, size <= 65_536 else { return [] }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, data) == noErr else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        let count = min(64, buffers.reduce(0) { $0 + Int($1.mNumberChannels) })
        guard count > 0 else { return [] }
        return (1...UInt32(count)).filter { writable(device, address(selector, channel: $0)) }
    }
    func gains(_ device: UInt32) throws -> [AudioGain] {
        try channels(device, selector: kAudioDevicePropertyVolumeScalar).map { channel in
            let value: Float32 = try read(device, address(kAudioDevicePropertyVolumeScalar, channel: channel), initial: Float32(0))
            guard value.isFinite else { throw OutputAudioError.unsupported }
            return AudioGain(channel: channel, value: min(1, max(0, value)))
        }
    }
    func setGain(_ device: UInt32, channel: UInt32, value: Float32) throws {
        try write(device, address(kAudioDevicePropertyVolumeScalar, channel: channel), value: min(1, max(0, value)))
    }
    func mutes(_ device: UInt32) throws -> [AudioMute] {
        try channels(device, selector: kAudioDevicePropertyMute).map { channel in
            let value: UInt32 = try read(device, address(kAudioDevicePropertyMute, channel: channel), initial: UInt32(0))
            return AudioMute(channel: channel, muted: value != 0)
        }
    }
    func setMute(_ device: UInt32, channel: UInt32, muted: Bool) throws {
        try write(device, address(kAudioDevicePropertyMute, channel: channel), value: UInt32(muted ? 1 : 0))
    }
}

/// Trackpads use accumulated travel; momentum is ignored to avoid continuing to
/// raise the volume after fingers lift. Physical wheel-up always means louder.
struct VolumeScrollAccumulator {
    private var remainder = 0.0
    mutating func change(delta: Double, precise: Bool, inverted: Bool, momentum: Bool, began: Bool = false, ended: Bool = false) -> Float32? {
        if began || ended { remainder = 0 }
        guard delta.isFinite, !momentum, !ended else { return nil }
        let physical = inverted ? -delta : delta
        if precise {
            remainder += physical
            let steps = max(-4, min(4, Int(remainder / 12)))
            remainder -= Double(steps) * 12
            return steps == 0 ? nil : Float32(steps) * 0.04
        }
        guard abs(physical) > 0.001 else { return nil }
        return Float32(max(-4, min(4, physical))) * 0.04
    }
}

/// The transparent overlay participates only in scrolling and middle-button
/// input. Left/right clicks continue to the native status button and its menu.
final class StatusAudioView: NSView {
    var enabled: () -> Bool = { false }
    var adjust: ((Float32) -> Void)?
    var toggleMute: (() -> Void)?
    private var middleHeld = false
    private var scroll = VolumeScrollAccumulator()
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let event = NSApp.currentEvent else { return nil }
        let button = [NSEvent.EventType.otherMouseDown, .otherMouseUp].contains(event.type) ? event.buttonNumber : 0
        return captures(type: event.type, button: button) ? self : nil
    }
    func captures(type: NSEvent.EventType, button: Int) -> Bool {
        if type == .scrollWheel { return enabled() }
        return button == 2 && [NSEvent.EventType.otherMouseDown, .otherMouseUp].contains(type) && (enabled() || middleHeld)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) {
        guard enabled() else { return }
        guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return }
        if let delta = scroll.change(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                     inverted: event.isDirectionInvertedFromDevice, momentum: !event.momentumPhase.isEmpty,
                                     began: event.phase.contains(.began), ended: event.phase.contains(.ended) || event.phase.contains(.cancelled)) { adjust?(delta) }
    }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 && enabled() { middleHeld = true } }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, middleHeld else { return }
        middleHeld = false
        if enabled(), bounds.contains(convert(event.locationInWindow, from: nil)) { toggleMute?() }
    }
}
