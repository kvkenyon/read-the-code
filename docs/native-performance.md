# Native performance bounds and evidence

RTC-206 adds deterministic containment limits, not end-user latency claims. The representative and stress budgets from the architecture blueprint have not been run against a composed native app.

| Boundary                                       | Implemented limit |
| ---------------------------------------------- | ----------------: |
| IPC frame                                      |             4 MiB |
| IPC tour payload                               |             1 MiB |
| Per-tour export preflight input estimate       |             1 MiB |
| Normal export                                  |             4 MiB |
| Normal-export aggregate input estimate         |             4 MiB |
| Diagnostic bundle contents                     |             4 MiB |
| Diagnostic approved input aggregate            |             4 MiB |
| Diagnostic files, including review and metrics |                16 |
| Approved diagnostic text attachment            |           256 KiB |
| Typed diagnostic records                       |               256 |
| Diagnostic string before truncation marker     |            32 KiB |
| Diagnostic preview redaction items             |             1,024 |
| Exported review events                         |            10,000 |
| Exported comment threads                       |            10,000 |
| Exported thread messages                       |            50,000 |
| Exported tours                                 |                32 |
| Diagram groups / aggregate members             |          64 / 512 |
| Tour risks / bullet items                      |         100 / 512 |

Normal export ordering is stable: events/messages are sequence-sorted, threads/tours use stable IDs, progress/files use path order where applicable, and JSON keys are sorted. Deterministic output avoids cache and digest churn. Diagnostic logical manifests are stable for identical review, typed records, and attachment content. Confirmation/pending nonces, staging names, destinations, modes, and filesystem timestamps are intentionally outside the determinism scope.

`RTCExportTests` exercises deterministic output and cap behavior as a Command Line Tools executable smoke. It is functional evidence only; it does not establish p50/p95 latency, memory, scrolling, launch, notification, XPC isolation, soak, or signed-package performance.

The shipped Node/browser characterization remains in [performance.md](performance.md): its 2026-08-09 baseline measured the 101-file/5,000-line fixture at 1,685 ms to open on that machine. That value is a migration reference, not evidence for native performance.
