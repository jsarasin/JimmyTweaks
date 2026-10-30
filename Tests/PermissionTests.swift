import Foundation
import Testing

@Test @MainActor func newlyGrantedAccessibilityAcquiresInputAccess() {
    var trusted = false
    var posting = false
    var preflightChecks = 0
    var requests = 0
    let permissions = PermissionCoordinator(
        checkAccessibility: { trusted },
        checkEventPosting: { preflightChecks += 1; return posting },
        requestEventPosting: { requests += 1; posting = true; return true })
    #expect(!permissions.ready)
    #expect(preflightChecks == 0)
    #expect(requests == 0)

    var notifications = 0
    let observer = NotificationCenter.default.addObserver(forName: .permissionsChanged, object: permissions, queue: nil) { _ in
        notifications += 1
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    trusted = true
    permissions.refresh()
    #expect(permissions.ready)
    #expect(requests == 1)
    #expect(notifications == 1)
    permissions.refresh()
    #expect(requests == 1)
    #expect(notifications == 1)

    trusted = false
    posting = false
    permissions.refresh()
    #expect(!permissions.ready)
    trusted = true
    permissions.refresh()
    #expect(permissions.ready)
    #expect(requests == 2)
}

@Test @MainActor func deniedInputAccessDoesNotRepeatedlyPrompt() {
    var requests = 0
    let permissions = PermissionCoordinator(
        checkAccessibility: { true }, checkEventPosting: { false },
        requestEventPosting: { requests += 1; return false })
    permissions.refresh()
    permissions.refresh()
    #expect(!permissions.ready)
    #expect(requests == 1)
}
