import Foundation

enum PermissionTests {
    static func run() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) { checks += 1; assert(value(), "Permission transition regression") }
        func newlyGrantedAccessibilityAcquiresInputAccess() {
            var trusted = false
            var posting = false
            var preflightChecks = 0
            var requests = 0
            let permissions = PermissionCoordinator(
                checkAccessibility: { trusted },
                checkEventPosting: { preflightChecks += 1; return posting },
                requestEventPosting: { requests += 1; posting = true; return true },
                checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
            check(!permissions.ready)
            check(preflightChecks == 0)
            check(requests == 0)

            var notifications = 0
            let observer = NotificationCenter.default.addObserver(forName: .permissionsChanged, object: permissions, queue: nil) { _ in
                notifications += 1
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            trusted = true
            permissions.refresh()
            check(permissions.ready)
            check(requests == 1)
            check(notifications == 1)
            permissions.refresh()
            check(requests == 1)
            check(notifications == 1)

            trusted = false
            posting = false
            permissions.refresh()
            check(!permissions.ready)
            trusted = true
            permissions.refresh()
            check(permissions.ready)
            check(requests == 2)
        }

        func deniedInputAccessDoesNotRepeatedlyPrompt() {
            var requests = 0
            let permissions = PermissionCoordinator(
                checkAccessibility: { true }, checkEventPosting: { false },
                requestEventPosting: { requests += 1; return false },
                checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
            permissions.refresh()
            permissions.refresh()
            check(!permissions.ready)
            check(requests == 1)
        }
        newlyGrantedAccessibilityAcquiresInputAccess()
        deniedInputAccessDoesNotRepeatedlyPrompt()
        print("\(checks) permission transition checks passed: fresh Accessibility grants acquire input access without repeated denial prompts.")
    }
}
