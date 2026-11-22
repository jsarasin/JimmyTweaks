Jimmy Tweaks V0.5.1 for **Apple silicon Macs running macOS 27 or later**.

- Replaced the Reoccurring Scripts preview with functional HTTP/API requests: configurable URL, method, headers, and JSON/text body.
- Added **Manual Only** and **Run Once**, alongside preset/custom interval schedules and daily local clock times.
- Added saved run history with HTTP status, duration, response headers, and bounded response bodies. Quit cancels all requests and timers; the request module installs no background worker.
- Included Awake & Sleep sessions, the optional authenticated closed-lid power helper, and worker update/fresh-install cleanup improvements.
- Improved explicit permission requests and status guidance, Settings navigation, narrow layouts, and focused regression tooling.

### Download and install

Download `Jimmy-Tweaks-0.5.1-macos-arm64.zip`, extract it, and move **Jimmy Tweaks.app** to Applications. Read `INSTALL.txt`, open the app from Applications, and follow the permission guidance. Verify the archive against `SHA256SUMS.txt`.

**Signing:** This optimized Release build is ad-hoc signed and is **not Developer ID signed or notarized**. macOS may block opening it. Automatic login registration is unavailable. Approved closed-lid helper installation requires a properly signed/notarized distribution; ordinary idle-sleep prevention does not require that helper. Icon Absorber remains experimental.

Request definitions, configured headers/bodies, and the latest 100 responses are stored locally in private app-owned storage. Response bodies retain up to 64 KiB each. Requests have no automatic application-level retries or redirects, and missed scheduled runs are skipped. Remote response content is displayed as plain text and never executed.

### Validation

Passed 7,745 core checks, source boundaries, engine/AX, permission, shortcut, request transport/scheduling and loopback HTTP checks, Awake & Sleep/worker lifecycle, Settings/Visual Effects, Icon Absorber, Snow Storm, Christmas, Fireplace, desktop interaction, and ten-page native UI smoke checks. Corrected the previously documented desktop test's race between admission-time and later foreground-window snapshots.

Development and optimized Release builds, strict nested signature checks, archive integrity, and extracted-app verification passed. See `VALIDATION.md` and `Docs/RecurringRequests.md` in the source for details and remaining manual hardware/permission checks.
