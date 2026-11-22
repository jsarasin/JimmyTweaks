import Foundation
import IOKit.hidsystem

enum PermissionTests {
    static func run() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) { checks += 1; assert(value(), "Permission transition regression") }
        func nativeInputMonitoringRequestsEvenWhenListeningIsAvailable() {
            for initialAccess in [kIOHIDAccessTypeUnknown, kIOHIDAccessTypeDenied, kIOHIDAccessTypeGranted,
                                  IOHIDAccessType(rawValue: UInt32.max)] {
                var access = initialAccess
                var requests = 0, nativeChecks = 0
                let native = InputMonitoringAccess(checkAccess: { type in
                    check(type == kIOHIDRequestTypeListenEvent)
                    nativeChecks += 1
                    return access
                }, requestAccess: { type in
                    check(type == kIOHIDRequestTypeListenEvent)
                    requests += 1
                    // A successful request is deliberately not an observed grant.
                    return true
                })
                let permissions = PermissionCoordinator(
                    checkAccessibility: { true }, checkEventPosting: { true }, requestEventPosting: { assertionFailure(); return false },
                    checkScreenRecording: { true }, requestAccessibility: { assertionFailure(); return false },
                    requestScreenRecording: { assertionFailure(); return false }, inputMonitoringAccess: native)
                defer { permissions.stopMonitoringForTermination() }
                let initiallyGranted = initialAccess == kIOHIDAccessTypeGranted
                check(nativeChecks == 1 && requests == 0)
                check(permissions.ready && permissions.inputMonitoring == initiallyGranted)
                permissions.setDetailed("input-regression", visible: true)
                check(permissions.pollingIntervalForTesting == 30)
                permissions.showStartupNotice { _, _ in }
                permissions.refresh()
                check(requests == 0)
                permissions.request(.inputMonitoring)
                permissions.request(.inputMonitoring)
                check(requests == 2)
                check(permissions.inputMonitoring == initiallyGranted && permissions.allGranted)

                var notifications = 0
                let observer = NotificationCenter.default.addObserver(forName: .permissionsChanged, object: permissions, queue: nil) { _ in notifications += 1 }
                defer { NotificationCenter.default.removeObserver(observer) }
                access = kIOHIDAccessTypeGranted
                permissions.refresh()
                check(permissions.allGranted && permissions.pollingIntervalForTesting == 30)
                check(notifications == (initiallyGranted ? 0 : 1))
                permissions.refresh()
                check(notifications == (initiallyGranted ? 0 : 1))
                access = kIOHIDAccessTypeDenied
                permissions.refresh()
                check(!permissions.inputMonitoring && permissions.allGranted && permissions.ready)
                check(permissions.pollingIntervalForTesting == 30)
                check(notifications == (initiallyGranted ? 1 : 2))
                check(requests == 2)
            }
        }
        func checksAndStartupNeverRequest() {
            // Include every combination, also covering AX approval with posting unavailable.
            for mask in 0..<8 {
                var trusted = mask & 1 != 0, listening = mask & 2 != 0, recording = mask & 4 != 0
                var requests = 0, notices: [(String, String)] = []
                let permissions = PermissionCoordinator(
                    checkAccessibility: { trusted }, checkEventPosting: { false }, requestEventPosting: { requests += 1; return false },
                    checkListening: { listening }, requestListening: { requests += 1; return false }, checkScreenRecording: { recording },
                    requestAccessibility: { requests += 1; return false }, requestScreenRecording: { requests += 1; return false })
                defer { permissions.stopMonitoringForTermination() }
                let expected = PermissionEntry.allCases.enumerated().filter { mask & (1 << $0.offset) == 0 && !($0.element == .inputMonitoring && trusted) }.map(\.element)
                check(permissions.missingPermissions == expected)
                permissions.showStartupNotice { notices.append(($0, $1)) }
                permissions.showStartupNotice { notices.append(($0, $1)) }
                check(notices.count == (expected.isEmpty ? 0 : 1))
                if let notice = notices.first {
                    check(notice.0 == "Permissions Not Approved")
                    let lines = notice.1.components(separatedBy: "\n").filter { $0.hasPrefix("• ") }
                    check(lines == expected.map { "• \($0.title)" })
                    check(notice.1.contains("Open Permissions in Jimmy Tweaks"))
                }
                trusted.toggle(); listening.toggle(); recording.toggle()
                permissions.refresh(); permissions.refresh()
                permissions.showStartupNotice { notices.append(($0, $1)) }
                check(notices.count == (expected.isEmpty ? 0 : 1))
                check(requests == 0)
            }
        }
        func explicitRequestsAreIsolatedAndRetryable() {
            var trusted = false, posting = false, listening = false, recording = false
            var axRequests = 0, postRequests = 0, listenRequests = 0, screenRequests = 0
            let permissions = PermissionCoordinator(
                checkAccessibility: { trusted }, checkEventPosting: { posting }, requestEventPosting: { postRequests += 1; return true },
                checkListening: { listening }, requestListening: { listenRequests += 1; return true }, checkScreenRecording: { recording },
                requestAccessibility: { axRequests += 1; return true }, requestScreenRecording: { screenRequests += 1; return true })
            permissions.request(.accessibility)
            check(axRequests == 1 && postRequests == 0 && listenRequests == 0 && screenRequests == 0)
            check(!permissions.accessibility && !permissions.ready)
            trusted = true
            permissions.refresh()
            check(postRequests == 0 && !permissions.ready)
            permissions.request(.accessibility)
            permissions.request(.accessibility)
            check(axRequests == 1 && postRequests == 2 && !permissions.ready)
            posting = true
            permissions.request(.accessibility)
            check(permissions.ready && postRequests == 2)
            permissions.request(.inputMonitoring)
            permissions.request(.inputMonitoring)
            check(listenRequests == 2 && !permissions.inputMonitoring && screenRequests == 0)
            listening = true
            permissions.request(.inputMonitoring)
            check(listenRequests == 3 && permissions.inputMonitoring)
            permissions.request(.screenRecording)
            permissions.request(.screenRecording)
            check(screenRequests == 2 && !permissions.screenRecording)
            recording = true
            permissions.request(.screenRecording)
            check(screenRequests == 2 && permissions.allGranted)
            permissions.stopMonitoringForTermination()
            trusted = false; posting = false; listening = false; recording = false
            for permission in PermissionEntry.allCases { permissions.request(permission) }
            permissions.showStartupNotice { _, _ in assertionFailure("No dialog after termination") }
            check(axRequests == 1 && postRequests == 2 && listenRequests == 3 && screenRequests == 2)

            // A synchronous AX approval can acquire posting access in the same explicit action.
            var approved = false, postingApproved = false
            let synchronous = PermissionCoordinator(
                checkAccessibility: { approved }, checkEventPosting: { postingApproved },
                requestEventPosting: { postingApproved = true; return true }, checkListening: { false },
                requestListening: { assertionFailure(); return false }, checkScreenRecording: { false },
                requestAccessibility: { approved = true; return true }, requestScreenRecording: { assertionFailure(); return false })
            synchronous.request(.accessibility)
            check(synchronous.ready)
            synchronous.stopMonitoringForTermination()
        }
        func visiblePagePollsUntilAllGranted() {
            var trusted = true, recording = false, requests = 0
            let permissions = PermissionCoordinator(
                checkAccessibility: { trusted }, checkEventPosting: { true }, requestEventPosting: { requests += 1; return false },
                checkListening: { true }, requestListening: { requests += 1; return false }, checkScreenRecording: { recording },
                requestAccessibility: { requests += 1; return false }, requestScreenRecording: { requests += 1; return false })
            check(permissions.pollingIntervalForTesting == nil)
            permissions.setBackgroundEligible(true)
            check(permissions.pollingIntervalForTesting == 30)
            permissions.setDetailed("permissions-page", visible: true)
            check(permissions.pollingIntervalForTesting == 2)
            recording = true
            let deadline = Date().addingTimeInterval(3)
            while !permissions.allGranted && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            check(permissions.allGranted && permissions.pollingIntervalForTesting == 30)
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
            permissions.refresh()
            permissions.setDetailed("permissions-page", visible: true)
            check(permissions.pollingIntervalForTesting == nil && requests == 0)
        }
        nativeInputMonitoringRequestsEvenWhenListeningIsAvailable()
        checksAndStartupNeverRequest()
        explicitRequestsAreIsolatedAndRetryable()
        visiblePagePollsUntilAllGranted()
        print("\(checks) permission checks passed: read-only startup/polling, missing-permission notices, explicit requests, grants/revocations, and shutdown.")
    }
}
