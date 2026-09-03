# Native packaging preparation

This directory is a deliberately non-publishing preparation surface for the
Developer ID, hardened-runtime, notarized macOS 14 distribution described by
`docs/adr/0001-platform.md`.

- `scripts/native-release/validate-release-config.sh` validates the committed,
  non-secret configuration, entitlements, and unpublished Sparkle template.
- `scripts/native-release/generate-sbom.mjs` writes an SPDX-like JSON inventory
  from the pinned Swift package resolution. It never contacts a registry.
- `scripts/native-release/require-full-xcode.sh` exits 69 with a clear message
  when only Command Line Tools are selected.
- `scripts/native-release/native-release-dry-run.sh` validates the deferred
  archive, signing, notarization, stapling, DMG/ZIP, appcast, and clean-install
  handoff without invoking any of those operations.

Release operators must supply signing identities, notarization credentials, and
the Sparkle public/private signing material outside this repository. This slice
neither reads those values nor creates, uploads, publishes, or rotates them.
`appcast.xml.template` is intentionally not a feed and must never be uploaded.
