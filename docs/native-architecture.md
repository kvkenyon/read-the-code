# Native source architecture

The native tree is a SwiftPM/XcodeGen module graph targeting macOS 14. The current source graph and demo application compile with Command Line Tools; it is not yet a signed, notarized, or release-qualified product.

```text
RTCContracts
  ├─ RTCGit / RTCStore / RTCIPC / RTCTour / RTCDiagram
  ├─ RTCDomain ── RTCReview
  └─ RTCExport ── consumes RTCReview + RTCTour + RTCDiagram + RTCIPC
```

`RTCContracts` owns schema-v2 Codable/Sendable values and service protocols. `RTCGit` materializes exact committed-tree reviews. `RTCStore` provides SQLite repositories and immutable blobs. `RTCIPC` provides bounded same-user/capability transport. `RTCDomain` and `RTCReview` enforce revision-bound mutations. `RTCTour` and `RTCDiagram` validate structured explanatory content.

`RTCExport` is a local boundary with no dependency on the store, model adapters, lifecycle, or a network client. Its IPC dependency is limited to composing the export operation handlers. Callers provide an immutable `ReviewExportInput` and an `AnchorArtifactSource`. Normal export constructs a new portable JSON tree from explicit fields, so internal `RevisionIdentity.repositoryPath`, diff hunks, opaque blobs, configuration, and credentials never cross the boundary. Aggregate counts and input bytes are rejected before anchor resolution or export-tree construction; tours then pass through the landed tour and diagram validators before conversion.

Diagnostic preparation adds typed per-field serialization and stages a directory bundle privately. `PendingDiagnosticExport` is an actor-isolated one-shot state machine. `DiagnosticExportIPCComposition` creates separate preparation and confirmation dispatchers with disjoint capabilities and a shared opaque pending registry. Only the confirmation handler owns the private short-lived, one-use approval authority. The staging root descriptor remains open from no-follow creation through leaf writes, atomic rename, publication, and cleanup; path replacement cannot redirect the operation. Publication uses a separately opened no-follow destination descriptor and exclusive rename. The module performs no upload.

`native/Package.swift` and `native/project.yml` keep the SwiftPM and XcodeGen app dependency graphs synchronized. `scripts/validate-native-manifests.mjs` validates both manifests, and `scripts/validate-native-skill.swift` mechanically compares the portable skill with the native CLI parser surface.

The `ReadTheCode` composition root starts the private ingest runtime and socket, renders the Inbox, and opens a stored exact revision through the existing diff, comment, deterministic tour, bounded-diagram, and durable conversation features. The local **Open Repository…** path resolves and reviews `HEAD^` → `HEAD`; submitted reviews use the same composition. Tour rendering resolves only from the immutable stored manifest, and every review mutation re-resolves the submitted refs and repository identity before it can append an event. The worker rail truthfully remains offline unless an external worker transport is connected.

A raw `swift run --package-path native ReadTheCode` process has no application-bundle proxy, so the composition root does not instantiate `UNUserNotificationCenter` there. Generated `.app` builds retain the system notification presenter. The private capability, spool, and database stay under Application Support; only the ephemeral Unix socket uses a deterministic, UID-scoped `/tmp` name so it remains within Darwin's short `sockaddr_un` limit. Same-UID authentication, mode-`0600` socket access, and the operation allowlist still guard every request. Export confirmation UI, worker-chat IPC routing, complete native CLI operations, full-Xcode UI checks, signing, notarization, and final packaging remain unimplemented or unverified as documented in [protocol v2](protocol-v2.md) and [native security](native-security.md).
