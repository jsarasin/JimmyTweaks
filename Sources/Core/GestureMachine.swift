import Foundation
import CoreGraphics

enum MouseButton: Equatable { case left, right }
struct Modifiers: Equatable {
    var command: Bool
    var extra: Bool
    var qualifies: Bool { command && !extra }
}
enum GestureInput {
    case down(MouseButton, CGPoint, Modifiers)
    case drag(MouseButton, CGPoint)
    case up(MouseButton, CGPoint)
    case flags(Modifiers)
    case escapeDown, escapeUp, interrupt
}
enum GestureEffect: Equatable {
    case resolve(UInt64, CGPoint, MouseButton)
    case holdDown, holdDrag, replay, discard
    case began(GestureKind), apply(CGPoint)
    case end(flush: Bool, reason: String), restore
    case hideFeedback
}
struct GestureDecision {
    var suppress = false
    var effects: [GestureEffect] = []
}

/// Pure event ownership reducer. It never calls the OS or retains native input events.
struct GestureMachine {
    enum Phase: Equatable { case idle, resolving, pending, active, draining, passThrough }
    struct Session {
        let id: UInt64
        let button: MouseButton
        let initial: CGPoint
        let preferences: GesturePreferences
        var latest: CGPoint
        var kind: GestureKind?
    }
    private(set) var phase: Phase = .idle
    private(set) var session: Session?
    private(set) var escapeOwned = false
    private var nextID: UInt64 = 0
    var ownsSequence: Bool { phase == .draining || phase == .active || phase == .pending || phase == .resolving || escapeOwned }
    var token: UInt64? { session?.id }

    mutating func handle(_ input: GestureInput, preferences: GesturePreferences, accepting: Bool) -> GestureDecision {
        if case .escapeUp = input {
            let owned = escapeOwned; escapeOwned = false
            return GestureDecision(suppress: owned)
        }
        if case .escapeDown = input {
            if escapeOwned { return GestureDecision(suppress: true) }
            if phase == .active || phase == .pending || phase == .resolving {
                escapeOwned = true
                let active = phase == .active; phase = .draining
                return GestureDecision(suppress: true, effects: active ? [.restore, .end(flush: false, reason: "escape"), .hideFeedback] : [.discard, .hideFeedback])
            }
            return GestureDecision()
        }
        switch input {
        case .down(let button, let point, let modifiers):
            if phase == .pending || phase == .resolving { return relinquish() }
            if phase == .active { return endActive(reason: "additional-button") }
            guard phase == .idle, !escapeOwned, accepting, preferences.anyGesture, modifiers.qualifies,
                  button == .left ? preferences.moveEnabled : preferences.resizeEnabled else { return GestureDecision() }
            nextID &+= 1
            session = Session(id: nextID, button: button, initial: point, preferences: preferences, latest: point)
            phase = .resolving
            return GestureDecision(suppress: true, effects: [.holdDown, .resolve(nextID, point, button)])
        case .drag(let button, let point):
            guard let s = session, s.button == button else { return GestureDecision() }
            session?.latest = point
            switch phase {
            case .resolving: return GestureDecision(suppress: true, effects: [.holdDrag])
            case .pending:
                if thresholdReached(point) { return activate() }
                return GestureDecision(suppress: true, effects: [.holdDrag])
            case .active: return GestureDecision(suppress: true, effects: [.apply(point)])
            case .draining: return GestureDecision(suppress: true)
            default: return GestureDecision()
            }
        case .up(let button, let point):
            guard let s = session, s.button == button else { return GestureDecision() }
            let old = phase; phase = .idle; session = nil
            switch old {
            case .active: return GestureDecision(suppress: true, effects: [.apply(point), .end(flush: true, reason: "mouse-up")])
            case .pending, .resolving: return GestureDecision(effects: [.replay, .hideFeedback])
            case .draining: return GestureDecision(suppress: true, effects: [.hideFeedback])
            default: return GestureDecision()
            }
        case .flags(let modifiers):
            if !modifiers.qualifies {
                if phase == .resolving || phase == .pending { return relinquish() }
                if phase == .active { return endActive(reason: modifiers.command ? "additional-modifier" : "command-up") }
                return GestureDecision(effects: [.hideFeedback])
            }
        case .interrupt:
            if phase == .resolving || phase == .pending { return relinquish() }
            if phase == .active { return endActive(reason: "additional-input") }
        case .escapeDown, .escapeUp: break
        }
        return GestureDecision()
    }

    mutating func resolved(id: UInt64, kind: GestureKind?) -> GestureDecision {
        guard phase == .resolving, session?.id == id else { return GestureDecision() }
        guard let kind = kind else { return relinquish() }
        session?.kind = kind
        phase = .pending
        if let s = session, (s.button == .right && s.preferences.immediateResize) || thresholdReached(s.latest) { return activate() }
        return GestureDecision()
    }
    mutating func timeout(id: UInt64) -> GestureDecision {
        guard phase == .resolving, token == id else { return GestureDecision() }
        return relinquish()
    }
    mutating func cancel(replayPending: Bool, reason: String) -> GestureDecision {
        switch phase {
        case .active: return endActive(reason: reason)
        case .pending, .resolving:
            phase = replayPending ? .passThrough : .draining
            return GestureDecision(effects: [replayPending ? .replay : .discard, .hideFeedback])
        default: return GestureDecision(effects: [.hideFeedback])
        }
    }
    mutating func adoptDrain(_ button: MouseButton?, escape: Bool) {
        escapeOwned = escape
        if let button = button {
            nextID &+= 1; phase = .draining
            session = Session(id: nextID, button: button, initial: .zero, preferences: GesturePreferences(), latest: .zero)
        }
    }
    // Only the native-event owner knows whether a deferred replay has actually
    // been posted. An unsent down still belongs to us across a context boundary.
    mutating func discardDeferredReplay() {
        if phase == .passThrough { phase = .draining }
    }
    mutating func clearReleasedOwnership(mouseReleased: Bool, escapeReleased: Bool) {
        if phase == .draining && mouseReleased { phase = .idle; session = nil }
        if escapeReleased { escapeOwned = false }
    }
    private func thresholdReached(_ point: CGPoint) -> Bool {
        guard let s = session else { return false }
        return WindowGeometry.distance(point, s.initial) >= (s.button == .right ? s.preferences.resizeThreshold : s.preferences.moveThreshold)
    }
    private mutating func activate() -> GestureDecision {
        guard let s = session, let kind = s.kind else { return GestureDecision() }
        phase = .active
        return GestureDecision(suppress: true, effects: [.discard, .began(kind), .apply(s.latest)])
    }
    private mutating func relinquish() -> GestureDecision {
        phase = .passThrough
        return GestureDecision(effects: [.replay, .hideFeedback])
    }
    private mutating func endActive(reason: String) -> GestureDecision {
        phase = .draining
        return GestureDecision(effects: [.end(flush: false, reason: reason), .hideFeedback])
    }
}
