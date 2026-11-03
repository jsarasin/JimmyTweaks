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

        func startupRequestsMissingPermissionsOnce() {
            var axRequests = 0, listenRequests = 0, screenRequests = 0
            let permissions = PermissionCoordinator(
                checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { assertionFailure("No input posting without Accessibility"); return false },
                checkListening: { false }, requestListening: { listenRequests += 1; return false }, checkScreenRecording: { false },
                requestAccessibility: { axRequests += 1; return false }, requestScreenRecording: { screenRequests += 1; return false })
            check(axRequests == 0 && listenRequests == 0 && screenRequests == 0)
            permissions.requestStartupPermissions()
            check(axRequests == 1 && listenRequests == 1 && screenRequests == 1)
            permissions.requestStartupPermissions()
            permissions.requestShortcutObservation()
            permissions.refresh()
            permissions.refresh()
            check(axRequests == 1 && listenRequests == 1 && screenRequests == 1)
            check(!permissions.allGranted)
        }

        func startupSkipsGrantsAndPublishesNewOnes() {
            var trusted = false, listening = true, recording = false
            var axRequests = 0, listenRequests = 0, screenRequests = 0
            let permissions = PermissionCoordinator(
                checkAccessibility: { trusted }, checkEventPosting: { trusted }, requestEventPosting: { false },
                checkListening: { listening }, requestListening: { listenRequests += 1; return false }, checkScreenRecording: { recording },
                requestAccessibility: { axRequests += 1; trusted = true; return true },
                requestScreenRecording: { screenRequests += 1; recording = true; return true })
            permissions.requestStartupPermissions()
            check(axRequests == 1 && listenRequests == 0 && screenRequests == 1)
            check(permissions.allGranted)
            permissions.requestStartupPermissions()
            check(axRequests == 1 && listenRequests == 0 && screenRequests == 1)
            let alreadyGranted = PermissionCoordinator(
                checkAccessibility: { true }, checkEventPosting: { true }, requestEventPosting: { false },
                checkListening: { true }, requestListening: { listenRequests += 1; return false }, checkScreenRecording: { true },
                requestAccessibility: { axRequests += 1; return false }, requestScreenRecording: { screenRequests += 1; return false })
            alreadyGranted.requestStartupPermissions()
            check(alreadyGranted.allGranted)
            check(axRequests == 1 && listenRequests == 0 && screenRequests == 1)
            listening = false
            permissions.refresh()
            check(!permissions.allGranted && permissions.ready)
        }

        func visiblePagePollsUntilAllGranted() {
            var trusted = true, recording = false, requests = 0
            let permissions = PermissionCoordinator(
                checkAccessibility: { trusted }, checkEventPosting: { true }, requestEventPosting: { false },
                checkListening: { true }, requestListening: { requests += 1; return false }, checkScreenRecording: { recording },
                requestAccessibility: { requests += 1; return false }, requestScreenRecording: { requests += 1; return false })
            check(permissions.pollingIntervalForTesting == nil)
            permissions.setBackgroundEligible(true)
            check(permissions.pollingIntervalForTesting == 30)
            permissions.setDetailed("permissions-page", visible: true)
            check(permissions.pollingIntervalForTesting == 2)
            recording = true
            // Exercise the actual timer, not a manual refresh: a grant must update
            // the page and slow polling without a Check Again button.
            let deadline = Date().addingTimeInterval(3)
            while !permissions.allGranted && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            check(permissions.allGranted)
            check(permissions.pollingIntervalForTesting == 30)
            recording = false
            permissions.refresh()
            check(permissions.pollingIntervalForTesting == 2)
            permissions.setDetailed("permissions-page", visible: false)
            check(permissions.pollingIntervalForTesting == 30)
            trusted = false
            permissions.refresh()
            check(permissions.pollingIntervalForTesting == 2)
            permissions.setBackgroundEligible(false)
            check(permissions.pollingIntervalForTesting == nil)
            permissions.setDetailed("permissions-page", visible: true)
            check(permissions.pollingIntervalForTesting == 2)
            permissions.stopMonitoringForTermination()
            permissions.requestStartupPermissions()
            permissions.refresh()
            permissions.setDetailed("permissions-page", visible: true)
            check(permissions.pollingIntervalForTesting == nil)
            check(requests == 0)
        }
        newlyGrantedAccessibilityAcquiresInputAccess()
        deniedInputAccessDoesNotRepeatedlyPrompt()
        startupRequestsMissingPermissionsOnce()
        startupSkipsGrantsAndPublishesNewOnes()
        visiblePagePollsUntilAllGranted()
        print("\(checks) permission checks passed: one-time startup requests, automatic visible-page polling, grant/revocation transitions, and shutdown.")
    }
}
