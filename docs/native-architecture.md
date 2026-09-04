# Native source architecture

The native tree is a SwiftPM/XcodeGen module graph targeting macOS 14. The current source graph compiles with Command Line Tools; it is not yet the final composed or packaged product.

```text
RTCContracts
  ├─ RTCGit / RTCStore / RTCIPC / RTCTour / RTCDiagram
  ├─ RTCDomain ── RTCReview
  └─ RTCExport ── consumes RTCReview + RTCTour + RTCDiagram + RTCIPC
```

`RTCContracts` owns schema-v2 Codable/Sendable values and service protocols. `RTCGit` materializes exact committed-tree reviews. `RTCStore` provides SQLite repositories and immutable blobs. `RTCIPC` provides bounded same-user/capability transport. `RTCDomain` and `RTCReview` enforce revision-bound mutations. `RTCTour` and `RTCDiagram` validate structured explanatory content.

`RTCExport` is a local boundary with no dependency on the store, model adapters, lifecycle, or a network client. Its IPC dependency is limited to composing the export operation handlers. Callers provide an immutable `ReviewExportInput` and an `AnchorArtifactSource`. Normal export constructs a new portable JSON tree from explicit fields, so internal `RevisionIdentity.repositoryPath`, diff hunks, opaque blobs, configuration, and credentials never cross the boundary. Aggregate counts and input bytes are rejected before anchor resolution or export-tree construction; tours then pass through the landed tour and diagram validators before conversion.

Diagnostic preparation adds typed per-field serialization and stages a directory bundle privately. `PendingDiagnosticExport` is an actor-isolated one-shot state machine. `DiagnosticExportIPCComposition` creates separate preparation and confirmation dispatchers with disjoint capabilities and a shared opaque pending registry. Only the confirmation handler owns the private short-lived, one-use approval authority. The staging root descriptor remains open from no-follow creation through leaf writes, atomic rename, publication, and cleanup; path replacement cannot redirect the operation. Publication uses a separately opened no-follow destination descriptor and exclusive rename. The module performs no upload.

`native/Package.swift` and `native/project.yml` register only the new `RTCExport` source and `RTCExportTests` executable in this slice. `scripts/validate-native-manifests.mjs` keeps both manifest dependency graphs synchronized. `scripts/validate-native-skill.swift` mechanically compares the portable skill with the native CLI parser surface.

The `ReadTheCode` app target compiles `RTCExport`, and the two export IPC service dispatchers are implemented, but no socket listener, CLI execution path, confirmation UI, final feature composition, or signed packaging connects them yet. See the exact wire and export shapes in [protocol v2](protocol-v2.md) and current boundaries in [native security](native-security.md).
