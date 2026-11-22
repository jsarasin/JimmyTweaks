# Recurring Requests

Recurring Requests replaces the old Reoccurring Scripts preview in version 0.5.1. It sends HTTP requests; it never downloads or launches executable scripts.

Enable the module, add a request, and configure its HTTP/HTTPS URL, method, headers, and optional JSON or text body. Custom headers support authorization and API keys. Save validates the configuration. **Run Once** saves the current editor and sends one request, whether or not it has a schedule. New requests default to **Manual Only**. A duplicated request has scheduled execution disabled.

## Schedules and lifecycle

Choose Manual Only, a preset interval (5 or 30 minutes, 1 or 6 hours, or every 24 hours), a custom whole-minute interval (1–525,600), or daily at a local 24-hour clock time. Scheduled requests also need their individual enable switch. The first interval run occurs after the interval, rather than immediately. Run Once does not change the next scheduled time.

Closing Settings leaves the app and schedules running. Suspend All, actual system sleep, and an inactive user session cancel requests and pause schedules. Display sleep alone does not pause them. Wake, resume, and relaunch schedule the next future run; overdue requests are skipped. Daily schedules run once per local date; the first repeated time is used during fall-back and a nonexistent time advances to the next valid time during spring-forward. Clock/time-zone changes recalculate future runs.

Each request permits one active execution. Different requests can run independently; a scheduled run that arrives while its request is busy is skipped. Editing a running request affects later runs. Disabling a previously scheduled request or removing it cancels its active run.

Quit cancels every request and timer and invalidates the app-owned network sessions. This module registers no helper, daemon, login item, or background transfer session. A request already received by a server may have taken effect before cancellation.

## HTTP behavior

Supported methods: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS. GET and HEAD omit bodies. JSON is validated before sending. JSON and text content types are supplied automatically unless explicitly set. Header names are case-insensitive; duplicate names and line-break injection are rejected. Transport-owned Host, Content-Length, Transfer-Encoding, and Connection headers cannot be overridden.

HTTP and HTTPS endpoints can include localhost, IP addresses, and private-network hosts. HTTPS retains native certificate verification; there is no insecure-certificate bypass. The app's ATS exception allows arbitrary user-configured plain HTTP endpoints. Requests have a 60-second overall timeout, no automatic application-level retries, no automatic redirects, no persistent cookies, no credential storage integration, and no HTTP response caching. Use explicit authorization headers when needed.

## Local data

Definitions and the latest 100 results persist in `~/Library/Application Support/<bundle identifier>/RecurringRequests/state.json`. The directory is owner-only (0700) and the file owner-readable/writable (0600). Header values, URLs, request bodies, and response data are stored locally in that file; they are not encrypted by the app. The saved file is capped at 32 MiB, each request body at 1 MiB, and request headers at 64 KiB/100 rows.

History records the original name, start time, elapsed duration, HTTP status, outcome, bounded response headers, and up to 64 KiB of response body. Capture is streamed and truncation is marked. Text and JSON are selectable plain text; binary responses show their retained byte count. Response content is never rendered as HTML or executed. HTTP 2xx is success; other HTTP statuses, network errors, cancellation, and timeouts remain inspectable.

Request content, names, and response payloads are excluded from Settings search and general diagnostic logs. Clear History removes saved responses. Reset Recurring Requests cancels work, clears definitions/history, and disables the module. Full fresh-install cleanup removes its storage. If stored data is unreadable, scheduling stays disabled until an explicit reset replaces it.

## Verification

`Scripts/test.sh` covers validation, storage/permissions, interval and daily schedules including DST, manual-only execution, request construction, bounded responses, errors, cancellation, stale callbacks, suspension, and the native editor. A loopback-only HTTP fixture verifies real HTTP payloads, status handling, redirects, and cancellation without calling external APIs. Tests use temporary storage and never register request workers.
