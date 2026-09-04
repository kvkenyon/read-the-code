# Native security and privacy boundaries

This is the implemented native source boundary, not packaged-product or release evidence. The shipped Node/browser security policy remains in [`SECURITY.md`](../SECURITY.md).

## Review and transport boundary

- `RTCGit` invokes fixed `/usr/bin/git` directly with argument arrays, a scrubbed environment, time/output caps, disabled external diff/text conversion, and pathspec terminators. It reads committed Git objects and does not execute repository content.
- `RTCIPC` uses a private Unix socket rather than a browser/TCP server. On Darwin, dispatch requires the current effective UID and a capability explicitly mapped to the requested operation. Frames are bounded before full decoding, clients and servers track absolute I/O deadlines, and in-flight clients are capped.
- `RTCStore` protects its root as `0700`, database/blob files as `0600`, and uses transactional SQLite plus atomic content-addressed blob writes.
- Tours and diagrams are bounded structured values. `TourValidator` resolves exact-revision anchors and rejects prohibited rich text; `DiagramValidator` checks graph identity, references, roles, groups, labels, and aggregate anchors.

## Export boundary

Normal native exports use a construction allowlist, not encode-then-delete filtering. They contain portable review summaries, relative file metadata, grammar-validated events, non-executable structured comments, decisions, progress, and exact-artifact-validated tours. Internal repository paths, diff/source blobs, capabilities, credential stores, raw prompts, environment, private state locations, IPC/model settings, and attachments are not representable. Recognizable path and credential patterns are scrubbed before a small positive plain-text grammar admits prose; code runs, markup delimiters, resource syntax, and executable syntax are rejected. Arbitrary allowed user-authored prose is still user data and is not claimed to be semantically secret-free.

Diagnostic export is deliberately different from normal export. Preparation accepts a closed typed record schema, applies recursive per-field serialization and lexical/encoded redaction, bounds collections/files/packages before staging, and returns a preview with opaque structural IDs. Preparation and confirmation have different dispatchers and capabilities; only the confirmation handler can issue and consume its private short-lived one-use approval. The pending actor excludes concurrent confirmation. A retained no-follow staging-root descriptor contains ancestor replacement, and descriptor-relative leaf creation records each leaf before any fallible write or synchronization so cleanup can remove partial work. No-follow publication rejects repository-contained and symlinked destinations, cleans failed temporary output, and never overwrites. Only approved UTF-8 attachments are eligible and their names are generated. No network client exists in `RTCExport`.

The preview reports schema-owned field IDs and redaction categories, not raw keys or removed values. A scrubbed diagnostic is still private data. In particular, arbitrary operator-approved attachment prose cannot be proven semantically secret-free.

## Evidence and remaining gates

`RTCExportTests` covers literal/percent/base64 path and credential canaries, event grammar, file/count/byte caps, deterministic normal output and diagnostic manifests, private staging permissions, generated filenames, disjoint prepare/confirm capabilities, expiry, concurrent one-shot confirmation, deterministic ancestor replacement, mid-write cancellation, injected write/sync failures, destination no-residue behavior, read-only and symlink-ancestor failures, post-publication cleanup failure, the side-specific diff-slice matrix, early aggregate rejection before anchor resolution, and nested hostile structured content. `scripts/native-check.sh` builds the SwiftPM graph and runs this smoke under Command Line Tools.

Full Xcode UI testing, signed application composition, Keychain provisioning, archive signing, notarization, stapling, clean installation, and packaged acceptance/security testing remain unverified. No claim in this document implies those gates passed.
