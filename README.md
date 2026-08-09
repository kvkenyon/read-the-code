# Read the Code

Review an exact local Git change set in a focused browser UI—without pushing a branch or opening a pull request.

Read the Code is a standalone, local-first product. `read-the-code-axi` resolves immutable base and head commits, starts an authenticated loopback server, and opens a polished review surface for file navigation, unified or split diffs, line and general comments, batched feedback, and exact-revision approval. The same versioned records power the browser and the CLI.

![Read the Code reviewing a local TypeScript change](docs/screenshot.png)

## Quick start

Node.js 20.12 or newer and Git are required.

```bash
npx -y read-the-code-axi open \
  --repo /path/to/repository \
  --base main \
  --head feature/my-change
```

The package is not published as part of this repository foundation. From a clone, use:

```bash
npm install
npm run build
npx read-the-code-axi open --repo . --base main --head HEAD
```

`open` resolves both refs before creating the review. Repeating the command for the same repository and SHAs resumes the same session idempotently. Add `--no-browser --json` for agent use.

## CLI

```text
read-the-code-axi open --repo <path> --base <ref> --head <ref> [--no-browser] [--json]
read-the-code-axi status <session> [--json]
read-the-code-axi poll <session> [--after <cursor>] [--timeout <duration>] [--json]
read-the-code-axi export <session> [--diagnostic] [--json]
read-the-code-axi end <session> [--json]
```

Durations accept `ms`, `s`, or `m`, such as `500ms`, `30s`, and `2m`. JSON responses use `schemaVersion: 1`. Errors sent with `--json` are also structured and written to stderr.

### Agent loop

`poll` never deletes events. Every feedback batch, approval, and end event has a durable, monotonically increasing `sequence`. Store `nextCursor` only after processing the returned events, then pass it back with `--after`; restarting a polling process cannot lose queued feedback.

```bash
review=$(read-the-code-axi open \
  --repo "$PWD" --base main --head HEAD --no-browser --json)
session=$(printf '%s' "$review" | jq -r .sessionId)
cursor=0

while true; do
  result=$(read-the-code-axi poll "$session" --after "$cursor" --timeout 2m --json)
  printf '%s\n' "$result" | jq '.events[]'
  cursor=$(printf '%s' "$result" | jq -r .nextCursor)
  printf '%s' "$result" | jq -e '.events[] | select(.type == "end")' >/dev/null && break
done

read-the-code-axi export "$session" --json > review-record.json
```

Human text output is the default. Machine consumers should use JSON and treat these exit codes as stable categories:

| Exit | Meaning                                        |
| ---: | ---------------------------------------------- |
|    0 | Success, including poll timeout                |
|    2 | Invalid argument, ref, anchor, or request      |
|    3 | Git operation failed                           |
|    4 | Configured size limit exceeded                 |
|    5 | Concurrent session operation stayed busy       |
|    6 | Session not found                              |
|    7 | Corrupt local state                            |
|    8 | Ended or stale revision conflict               |
|    9 | Authorization, origin, host, or bind rejection |
|   10 | Local server failed to start                   |

## Review experience

- Searchable changed-file navigation with reviewed state and comment counts.
- Unified and split syntax-highlighted diffs with additions, deletions, context, hunks, line numbers, renamed/deleted/added files, binary notices, and explicit large-file containment.
- Click a line to comment; Shift-click another line on the same side for a range.
- Editable draft comments, file comments, and general comments submitted together as one durable feedback event.
- Explicit approval bound to the displayed head SHA and a separate end-review action.
- Stale-head warning and invalidated approval state when the requested head ref moves.
- Keyboard navigation: <kbd>J</kbd>/<kbd>K</kbd> files, <kbd>U</kbd>/<kbd>S</kbd> layout, <kbd>G</kbd> general comment, and <kbd>Esc</kbd> cancel.
- Responsive file drawer and horizontally contained diffs on narrow screens.

The browser cannot edit or write source files.

## Privacy and security model

Normal operation makes no network requests beyond loopback. Frontend assets and syntax grammars are bundled in the npm package; there are no CDN assets, analytics, accounts, telemetry, cloud storage, or publishing service.

- The HTTP server binds only to `127.0.0.1` on an operating-system-assigned port.
- Each review has a random 256-bit capability token. The token is kept in a private state file and the browser URL fragment, so it is not sent in the initial HTTP request. APIs require it as a bearer capability.
- Server management uses a separate private capability. Tokens are never written into exports or server logs.
- Browser writes validate Host, Origin, content type, payload size, session capability, exact revision, path, side, line range, and contextual anchor hashes.
- Git is invoked directly without a shell, with external diff/text conversion disabled. Repository content is rendered as escaped text and is never executed.
- The browser API can only return the stored manifest and patch fragments for that review. It has no arbitrary filesystem endpoint.
- Sessions live under `$XDG_STATE_HOME/read-the-code` or `~/.local/state/read-the-code`; set `READ_THE_CODE_STATE_DIR` to override this for tests or isolated automation.
- Browser and machine exports omit absolute local paths. `export --diagnostic` is the explicit opt-in for the local repository path.

The authenticated local URL is a bearer capability. Share it only with processes and people who should access the review.

## Limits

This first release reviews two committed Git trees. It does not include unstaged changes, inline source editing, hosted sharing, remote collaboration, or PR synchronization. Patches are limited to 1 MB per file, 8 MB total, and 2,000 files. Binary contents are not rendered. Individual comments are limited to 20 KB and a batch to 100 comments/100 KB.

File review checkmarks are browser-local convenience state. Submitted comments, approvals, end events, and their cursors are durable session state.

## Development

```bash
npm install
npm run fixture        # creates .test-state/example-repository
npm run dev            # frontend development only
npm run check          # format, lint, types, unit/integration, build, packed install
npm run test:e2e       # real Chromium review workflow
npm run release:check  # complete local release gate and npm pack dry run
```

See [architecture](docs/architecture.md), [typed protocol](docs/protocol.md), and [contributing](CONTRIBUTING.md) for implementation details. Read the Code is available under the [MIT License](LICENSE).
