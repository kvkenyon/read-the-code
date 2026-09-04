# Native protocol and export contract (schema version 2)

This document describes the native source currently compiled by `scripts/native-check.sh`. It does not claim that the native app, CLI-to-app composition, installation, or packaging is complete. The shipped Node/browser protocol remains [schema version 1](protocol.md).

## Framing and authorization

`RTCIPC` frames canonical UTF-8 JSON as a four-byte big-endian length followed by the payload. Frames are capped at 4 MiB and tour payloads at 1 MiB. The wire envelope contains `protocolVersion`, `requestID`, `operation`, `capability`, and a data-encoded `body`. Dispatch checks the peer UID on Darwin, protocol major `2`, and an explicit capability-to-operation mapping before creating the schema-v2 `IPCRequest`; a capability for one operation is denied for every other operation. Responses echo the request ID and contain either a body or `IPCWireError`.

The native CLI parser currently recognizes:

```text
rtc submit --repo <path> --base <commit-ish> --head <commit-ish> [--metadata <json>] [--tour <json>] [--wake-file <path>] [--no-notify] [--json]
rtc status <review> [--json]
rtc poll <review> --after <cursor> [--timeout <duration>] [--full] [--json]
rtc conversation poll <review> --after <cursor> [--timeout <duration>] [--full] [--json]
rtc conversation reply <review> --message <json> [--json]
rtc tour attach <review> --file <json-file> [--json]
rtc export <review> [--diagnostic] [--full] [--json]
rtc close <review> [--json]
rtc install-skill [--scope user|project] [--json]
rtc [help | --help | -h]
```

The parser and IPC transport compile and have executable smoke coverage. The current source runtime executes `submit`, `status`, review `poll`, and `close` through the landed ingest IPC flow. Conversation, tour, export, and skill-install commands are parsed but intentionally return unavailable in this build. Native packaging remains unverified.

## Durable records

`ReviewManifest`, `ReviewEvent`, `ConversationEvent`, and `TourDocument` reject schema versions other than `2`. Reviews bind to a canonical repository path plus full base/head SHAs internally. The landed review event kinds are `threadCreated`, `threadMessageAdded`, `fileProgressChanged`, `feedback`, `changesRequested`, `approval`, `close`, `threadResolved`, and `threadReopened`. Event repositories replay ordered events after a caller cursor; consumers advance their checkpoint only after processing effects and use sequence or UUID for idempotency.

The contract intentionally keeps conversation events separate from formal review events. Conversation text cannot create approval or changes-requested authority.

## Native normal export

`RTCExport.ReviewExporter.normalExport` emits deterministic sorted-key JSON with this allowlisted top level:

```json
{
  "schemaVersion": 2,
  "exportKind": "normal",
  "review": {},
  "events": [],
  "comments": [],
  "decisions": [],
  "progress": [],
  "tours": []
}
```

The review revision contains only `baseSHA` and `headSHA`. File records contain relative path and bounded summary metadata, never hunks or source text. Each review event must carry the landed exact envelope `{ "data": <canonical JSON string>, "version": "1" }`; the decoded object must have the event kind's closed top-level shape. Export reconstructs only portable fields: structural events expose identifiers or file progress, formal events expose validated thread identifiers, bounded structured summaries, known state/count warnings, or thread identifiers, and approval/close take `headSHA` from the immutable event revision rather than payload text. Raw envelope data and unknown nested fields are never serialized. Comments serialize non-executable structured text runs and exact portable anchors. Diff slices name an explicit old/new side, exact hunk index, inclusive contiguous side-specific line range, and both endpoint context hashes; binary, truncated, mixed-side, gapped, mismatched, or unresolved slices are rejected. Tours are exported only after aggregate count/input-byte preflight, strict exact-revision and graph validation, and a positive portable plain-text grammar that excludes markup, resource, and executable forms.

There are no normal-export fields for the absolute repository path, capability, credential store, raw prompt, environment, state/socket/wake path, model/IPC configuration, or blobs. Text values are additionally scrubbed for recognizable absolute paths and credential patterns. User-authored comment and tour prose is portable user data, so arbitrary prose is not claimed to be semantically secret-free. Normal output is capped at 4 MiB, matching the landed IPC frame ceiling; collection caps are documented in [native performance](native-performance.md).

## Native diagnostic export

Diagnostics are a two-step library boundary:

1. `prepareDiagnosticExport` accepts only typed operation/phase/message/count/timing records, applies recursive per-field serialization plus recognizable literal/percent-encoded/base64-like path and credential redaction, omits unapproved attachments, generates attachment names with safe extensions, and atomically stages private files outside the reviewed repository. Collection and aggregate input limits are checked before staging.
2. It returns a preview with generated filenames, sizes, schema-owned field IDs, redaction categories, omitted attachment count, total bytes, and an opaque pending ID. It returns no confirmation bearer and publishes nothing.
3. Preparation and confirmation are separate IPC dispatchers with disjoint capabilities. The preparation service cannot issue or consume approval. The confirmation service owns the private authority that issues a short-lived one-use approval scoped to the pending ID, and the actor-isolated pending state atomically excludes concurrent consumption. Expired approval and pre-publication failures leave the pending export retryable; publication followed by staging-cleanup failure is reported distinctly and cannot be retried.
4. Staging and publication retain no-follow directory descriptors and use descriptor-relative creation, writing, synchronization, rename, and cleanup. Repository-contained, symlink-ancestor, replaced-path, and existing destinations are rejected or contained without redirecting writes.

The manifest hashes logical bundle contents deterministically. Pending/approval nonces, filesystem timestamps, private staging names, and publication destinations are outside that determinism claim. Approved attachment prose is arbitrary user-approved data: lexical redaction applies, but it cannot be proven semantically secret-free.

`RTCExport` contains no network or upload API. The diagnostic service composition is landed and compiled into the app graph, but the `rtc` executable still only parses the export flags; no CLI execution path, socket route to the export dispatchers, or confirmation UI is connected.

## Current error contract mismatch

The landed `RTCErrorCode` values are `INVALID_JSON`, `UNKNOWN_MAJOR`, `INVALID_REVISION`, `INVALID_REF`, `STALE_REVISION`, `INVALID_ANCHOR`, `LIMIT_EXCEEDED`, `GIT_TIMEOUT`, `GIT_CANCELLED`, `GIT_OUTPUT_LIMIT`, `UNAUTHORIZED`, `APP_UNAVAILABLE`, `TOUR_REJECTED`, `TOUR_ID_CONFLICT`, `INSUFFICIENT_GROUNDING`, `MODEL_UNAVAILABLE`, and `INTERNAL_ERROR`.

The IPC boundary also currently emits string-only `UNSUPPORTED_PROTOCOL` and `INVALID_ARGUMENT` errors. This differs from the earlier blueprint taxonomy. RTC-206 does not select or rename public errors; consumers must use only the landed values above until a separate contract decision reconciles them.

Source contracts are authoritative in [`RTCContracts`](../native/Sources/RTCContracts/Contracts.swift), [`RTCIPC`](../native/Sources/RTCIPC/RTCIPC.swift), and [`RTCExport`](../native/Sources/RTCExport/ReviewExporter.swift).
