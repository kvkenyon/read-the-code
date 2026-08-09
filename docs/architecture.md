# Architecture

Read the Code is one npm package with three deliberately small layers:

```text
read-the-code-axi CLI
  ├─ Git adapter ── resolves commits and asks Git for safe unified patches
  ├─ session store ── atomic JSON records + private capability files
  └─ loopback server
       ├─ versioned review/feedback API
       └─ bundled React review UI
```

There is no cloud component. The reviewed repository is an input, not a workspace: Read the Code never writes into it and does not execute its files.

## Revision construction

`open` canonicalizes the repository root and resolves `<ref>^{commit}` for both base and head. The review identity is the first 24 hexadecimal characters of SHA-256 over the canonical repository path, base SHA, and head SHA. The path influences the opaque id but is not recoverable from it.

Git runs through Node's `execFile`, never a shell. Every path-bearing command uses `--`; refs beginning with `-` and refs containing control characters are rejected. External diff drivers and text conversion are disabled. `git diff --name-status -z --find-renames` provides unambiguous filenames, including whitespace/newlines, while per-file unified patches keep memory and size accounting bounded. The working tree is not read as source—the committed trees are.

[`parse-diff`](https://www.npmjs.com/package/parse-diff) is the focused unified-patch parser. It avoids maintaining a bespoke hunk/line-number algorithm. [`highlight.js`](https://www.npmjs.com/package/highlight.js) supplies maintained language parsing; selected grammars are bundled into the browser build. React inserts filenames and comments as text, and highlight.js escapes code before returning token markup. A strict CSP blocks inline script and external loads as a second layer.

## State and lifecycle

The default state root is `$XDG_STATE_HOME/read-the-code`, falling back to `~/.local/state/read-the-code`. Directories use mode `0700`; JSON and capability files use `0600`.

```text
read-the-code/
  server.json             # port, PID, private management capability
  sessions/
    <session>.json        # manifest and append-only logical event list
    <session>.token       # browser/API capability, never exported
    <session>.lock        # short-lived cross-process write lock
```

Session updates acquire an exclusive lock and replace JSON atomically. Stale lock files older than 30 seconds can be recovered. The local server uses an OS-assigned port, writes its registry only after listening, and reuses a healthy instance. `end` closes one session; the daemon exits when no open session remains. Opening the exact revision again reopens/resumes its durable record.

The event list is append-only in meaning. `sequence` increases within a session and is never reused. A long-poll waits on an in-process notification rather than repeatedly reading. Events remain stored after delivery, so a client resumes with its last processed cursor and cannot lose a feedback batch during restart. This is intentionally a single-machine protocol, not a distributed queue.

## Anchors and stale revisions

A line anchor carries:

- exact base and head SHA;
- normalized changed-file path;
- old or new side;
- inclusive line range;
- a hash for each endpoint derived from path, line kind/numbers/text, and neighboring patch context.

Submission revalidates the anchor against the immutable stored patch. A mismatch fails as `STALE_ANCHOR`; comments are never guessed onto another line. Moving the requested head ref makes the session stale. Existing feedback stays attached to its original revision, existing approval is shown as stale, and new feedback and approval are rejected at their mutation boundaries. Opening the moved ref creates a different review identity.

Large-review characterization and the additive data-loading direction are documented in [`performance.md`](performance.md). Phase 1 keeps the stable monolithic manifest and event protocol intact.

## HTTP boundary

The server only accepts `127.0.0.1`. It validates the exact Host header and rejects a supplied Origin other than its own loopback origin. Browser/API session routes require the session bearer capability; the health route requires a distinct server-management capability. The token is placed after `#` in the browser URL and therefore is not part of the initial HTTP request.

Static serving is allowlisted to `index.html` and generated asset filenames. There is no route for arbitrary filesystem content. API errors are JSON with stable codes. Mutation requests require JSON, have a 128 KB transport cap, and receive narrower domain validation. Responses include CSP, no-sniff, frame denial, no-referrer, and restrictive permissions headers.

## Build and package

Vite creates hashed, offline browser assets under `dist/public`. tsup bundles the Node CLI and backend into `dist/cli.js`. The npm `files` allowlist contains `dist`, the canonical `skills` directory, the README, and license. `scripts/pack-smoke.mjs` packs the actual tarball, installs it into an isolated package, verifies standard-path skill discovery, and exercises the generated bin through the durable review lifecycle; this catches source-tree-only assumptions.

Node.js 20.12+ is the supported runtime. The code uses standard `fetch`, `AbortSignal.timeout`, `findLast`, and modern ESM.
