# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Node.js 20.12+ is the supported runtime. `npm run check` is the non-browser gate; `npm run test:e2e` adds the packaged real-browser workflow.
- `src/protocol.ts` is the typed contract shared by CLI, server, browser, exports, and tests. Update `docs/protocol.md` with any contract change.
- Reviews must remain exact committed-tree comparisons. Preserve direct, shell-free Git invocation, loopback-only serving, capability authorization, secret-free exports, and state outside reviewed repositories; see `docs/architecture.md`.
- `.test-state/` is the ignored home for generated repositories and isolated state during local tests. `npm run fixture` creates a representative repository there without touching another checkout.
- `skills/read-the-code/` is the canonical portable agent skill and ships in the npm tarball. Keep its documented CLI surface aligned with `src/cli.ts`; `npm run test:skill` validates the contract.
- Version tags matching `package.json` publish through `.github/workflows/release.yml` only after `npm run release:check`; keep the packed-install smoke in that gate.
- Native packaging preparation is intentionally unsigned and non-publishing: run `npm run test:native-packaging` for CLT-safe validation, and treat `scripts/native-release/require-full-xcode.sh` plus final archive/sign/notarize/clean-install work as later release-host gates.
- `scripts/native-check.sh` builds the landed SwiftPM graph, validates both native manifests, runs every executable smoke, and generates the Xcode project; under Command Line Tools it reports XCTest and Xcode-only gates as explicitly remaining.
- `swift run --package-path native ReadTheCode` is the CLT-safe local demo launch; raw SwiftPM processes intentionally disable system notifications, and native IPC uses the UID-scoped short socket documented in `docs/native-architecture.md`.
- `native/Sources/RTCSettings` owns private, versioned app settings and must retain the loopback-only adapter validation and credential-lookup boundary.
- Native exports are constructed through the `RTCExport` allowlist and diagnostic preview/confirmation boundary; keep its caps, redaction rules, skill-v2 contract, and evidence-scoped public docs aligned through `RTCExportTests` and `scripts/validate-native-skill.swift`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
