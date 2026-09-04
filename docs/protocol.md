# Typed local protocol, schema version 1

The browser and CLI expose the same records. JSON field names and event meanings described here are stable for schema version 1; additive fields may appear. Consumers must reject unsupported `schemaVersion` values rather than guessing.

The normal CLI surface is compact TOON intended for agent-readable summaries. It deliberately bounds long comments, paths, file lists, and archival output; use `--full` to expand that TOON view. This document is the separate stable automation contract: Sophon and other consumers that need exact identities, cursors, complete event bodies, or the local `open` capability must request `--json`. JSON semantics, event ordering, error categories, and `schemaVersion: 1` remain unchanged.

## Session metadata

`open --json` returns the capability-bearing local URL only to the invoking local process:

```json
{
  "schemaVersion": 1,
  "sessionId": "cae71af8a34aeb39220354a0",
  "baseSha": "40-hex-commit-id",
  "headSha": "40-hex-commit-id",
  "browserUrl": "http://127.0.0.1:49152/#/review/<session>/<capability>",
  "resumed": false,
  "wakeFileArmed": true,
  "status": "open"
}
```

`open --wake-file <path>` arms local instantiator delivery. The path is stored only in private session state and is omitted from normal output and exports. Each submission appends a mode-`0600` JSONL `ReviewWakeEvent` containing `schemaVersion`, `sessionId`, `sequence`, `type`, and the corresponding secret-free durable `event`. It never contains the browser URL or capability. Wake delivery tells an instantiator to call `poll`; it does not consume or acknowledge the append-only event.

`status --json` omits capabilities and paths. It includes revision SHAs, change summary, `stale`, `approvalStale`, event counts, the latest sequence, and timestamps.

The browser manifest includes repository display name, original ref labels, resolved SHAs, lifecycle/stale state, summary, and files. A file contains `path`, optional `oldPath`, status, counts, binary/truncated flags, and hunks. Each diff line contains its kind, nullable old/new number, plain text, and contextual hash.

Text files may also carry exact-tree old/new line counts so the UI can identify collapsed ranges. `GET .../context` accepts only a path already in the review, a real hunk index, `position=before|after`, and a bounded `lines` count from 1 through 200. It returns `ContextResult` with the total hidden count and old/new numbered context lines read from the session's pinned base/head blobs. It cannot name an arbitrary revision or filesystem path.

## Comment input

A feedback request batches one or more drafts:

```json
{
  "comments": [
    {
      "scope": "line",
      "path": "src/cart.ts",
      "body": "Should this round only at the formatting boundary?",
      "anchor": {
        "revision": { "baseSha": "…", "headSha": "…" },
        "path": "src/cart.ts",
        "side": "new",
        "startLine": 18,
        "endLine": 20,
        "contextHash": "24-hex-context-hash",
        "endContextHash": "24-hex-context-hash"
      }
    },
    {
      "scope": "general",
      "body": "The new boundary is much clearer."
    }
  ]
}
```

`scope` is `line`, `file`, or `general`. File comments require `path` and no anchor. General comments have neither. Line ranges must stay on one old/new side within one file.

## Durable events

All events share:

```ts
interface EventBase {
  schemaVersion: 1;
  sessionId: string;
  sequence: number; // monotonic within this session
  id: string; // UUID submission identity
  createdAt: string; // ISO 8601
  baseSha: string;
  headSha: string;
}
```

Feedback has `type: "feedback"` and a `comments` array. The server adds a UUID and timestamp to each comment. Approval has `type: "approval"` and `approvedHeadSha`, which always equals the event's exact `headSha`. End has `type: "end"`.

`poll <session> --after N --json` returns every event with `sequence > N`:

```json
{
  "schemaVersion": 1,
  "sessionId": "cae71af8a34aeb39220354a0",
  "after": 4,
  "nextCursor": 6,
  "timedOut": false,
  "events": ["event 5", "event 6"]
}
```

A timeout is successful and returns an empty event list with `timedOut: true` and an unchanged cursor. Delivery is non-destructive. For restart safety, a consumer processes events in ascending sequence, durably stores `nextCursor`, then issues the next poll. Replaying an old cursor intentionally replays events; UUID and sequence let consumers enforce their own exactly-once effects without hidden server acknowledgment state.

`export --json` returns `{ schemaVersion, session, events }`. It includes diff text and all durable review records, but no capability, server-management data, PID/port, or absolute path. `--diagnostic` adds `diagnostics.repositoryPath` explicitly for a trusted local caller.

## HTTP mapping

The UI uses these loopback-only routes with `Authorization: Bearer <session capability>`:

| Method | Route                                                                 | Result                     |
| ------ | --------------------------------------------------------------------- | -------------------------- |
| `GET`  | `/api/v1/sessions/:id`                                                | Review manifest            |
| `GET`  | `/api/v1/sessions/:id/events?after=N&timeout=MS`                      | Long-poll result           |
| `GET`  | `/api/v1/sessions/:id/context?path=P&hunk=N&position=before&lines=20` | Exact-tree hunk context    |
| `POST` | `/api/v1/sessions/:id/feedback`                                       | Created feedback event     |
| `POST` | `/api/v1/sessions/:id/approval`                                       | Created exact-SHA approval |
| `POST` | `/api/v1/sessions/:id/end`                                            | Idempotent end event       |

Feedback and approval return `STALE_REVISION` with HTTP 409 if the originally requested symbolic head no longer resolves to the session's exact head SHA. Existing events remain readable. The Phase 1 UI and hardening work do not change any successful JSON, TOON, event, or CLI shape; future index, per-file diff, and workspace routes are planned as additive surfaces.

The control ping is private implementation plumbing with a different local capability; it is not an integration API.

Errors have this shape:

```json
{ "schemaVersion": 1, "error": { "code": "STALE_ANCHOR", "message": "…" } }
```

Source TypeScript definitions are authoritative in [`src/protocol.ts`](../src/protocol.ts).

## Native agent conversation IPC

The native app's private same-UID IPC conversation capability is separate from
the loopback review protocol. It is scoped only to polling, replies, availability,
and acknowledgement; it cannot approve, request changes, close a review, or
mutate review evidence. The length-prefixed transport frame is capped at 4 MiB,
and this chat surface caps decoded operation payloads at 128 KB. Reply UUIDs
are durably journaled with an operation/payload digest; exact retries reuse the
stored result and conflicting reuse is rejected. Conversation pages replay from
private durable state after either endpoint restarts. Errors and status are
generic and never expose capabilities, paths, credentials, or prompt content.
Promotion creates only a proposed payload; the existing anchored review mutation
path must validate and explicitly apply any review effect.

## Native schema-version 2 review log

The native review workspace uses the contracts in `native/Sources/RTCContracts/Contracts.swift`. Its immutable `ReviewManifest` fixes the repository path and exact base/head commit pair. Workspace state is reconstructed by replaying `review_events` in contiguous per-review sequence order; a gap, duplicate event ID, wrong review/revision, malformed payload, invalid anchor, or illegal transition fails closed.

The native event kinds are `threadCreated`, `threadMessageAdded`, `fileProgressChanged`, `feedback`, `changesRequested`, `approval`, `close`, `threadResolved`, and `threadReopened`. The first three persist local workspace state. One user command appends one event: notably, `changesRequested` contains both the sorted draft IDs and actual bounded summary in one atomic event rather than emitting a preceding feedback event.

Callers submit a `PendingReviewEvent` with a stable operation UUID and the expected current sequence. `EventRepository.append(_:after:)` compares an existing UUID byte-for-byte for idempotent response-loss recovery, checks the exact non-stale review and expected tail, assigns the canonical next sequence inside the store transaction, and returns the stored `ReviewEvent`. The command handler retains the exact pending event, including its canonical payload and nested timestamps, across an ambiguous append error. A definite optimistic-tail conflict discards that candidate, replays the winning tail, and revalidates before preparing a replacement under the same operation UUID.

Every review-event payload uses the exact envelope `{ "data": <canonical JSON string>, "version": "1" }`. Hydration rejects noncanonical or duplicate-key JSON, missing or additional fields, wrong scalar types, excessive paths/comments/arrays, unsorted or duplicate identifier lists, and event-specific semantic violations before applying an event. In particular, `close` accepts only the canonical empty object as its data.

`threadCreated` fixes a context-hashed exact-revision anchor for the lifetime of the thread. Later events identify the thread but cannot replace its anchor. A moved symbolic head, unavailable mutation preflight, persisted stale manifest, or terminal review leaves prior evidence readable while all mutations fail closed. Local draft and file-progress events are excluded from worker-facing delivery until an explicit formal review action.
