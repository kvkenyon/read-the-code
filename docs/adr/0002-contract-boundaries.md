# ADR 0002: Contract and trust boundaries

Status: accepted provisional contract freeze (RTC-000)

`RTCContracts` contains Codable, Sendable value types and service protocols only. Reviews bind immutably to canonical repository path, full base SHA, and full head SHA. Events and IPC envelopes carry schema version 2 and stable error codes. Unknown schema majors are rejected.

Tour and conversation producers supply bounded structured values. Rich text has only plain/emphasis/strong/code runs; diagrams have semantic nodes, edges, groups, and review anchors. Raw HTML, Markdown execution, SVG, Mermaid, scripts, external resources, arbitrary URLs, and model coordinates are not contract fields. Review anchors are exact-revision and path/line/hash bound; an anchor mismatch is an error, never a guess.

Worker wakes are advisory ID-only records. Chat cannot grant review authority; only explicit feedback, request-changes, approval, and close events do. Secrets and capabilities are excluded from exports, wakes, logs, and notifications.
